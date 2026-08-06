defmodule Baileys.Store.S3Test.Requester do
  def request(operation, options) do
    send(Keyword.fetch!(options, :owner), {:s3_request, operation, options})

    case Keyword.fetch!(options, :response) do
      response when is_function(response, 1) -> response.(operation)
      response -> response
    end
  end
end

defmodule Baileys.Store.S3Test do
  use ExUnit.Case, async: true

  alias Baileys.Store.S3
  alias Baileys.Store.S3.Encryption.AESGCM
  alias Baileys.Store.S3Test.Requester

  test "validates required and optional configuration" do
    assert {:error, :bucket_required} = S3.init(region: "sa-east-1")
    assert {:error, :region_required} = S3.init(bucket: "sessions")
    assert {:error, :invalid_bucket} = S3.init(bucket: "", region: "sa-east-1")

    assert {:error, :invalid_prefix} =
             S3.init(bucket: "sessions", region: "sa-east-1", prefix: :invalid)

    assert {:error, :invalid_prefix} =
             S3.init(bucket: "sessions", region: "sa-east-1", prefix: "//")

    assert {:error, :invalid_ex_aws_options} =
             S3.init(bucket: "sessions", region: "sa-east-1", ex_aws_options: %{})

    assert {:error, :invalid_encryption} =
             S3.init(bucket: "sessions", region: "sa-east-1", encryption: :invalid)

    assert {:error, {:encryption, :invalid_key}} =
             S3.init(
               bucket: "sessions",
               region: "sa-east-1",
               encryption: {AESGCM, key: "short"}
             )
  end

  test "fetch records the ETag and builds the deterministic key" do
    response = {:ok, %{body: "payload", headers: [{"ETag", ~s("version-1")}]}}
    assert {:ok, state} = state(response, prefix: "/tenant/baileys/")
    assert {:ok, "payload"} = S3.fetch(state, "primary")

    assert_receive {:s3_request, operation, options}
    assert operation.http_method == :get
    assert operation.bucket == "sessions"
    assert operation.path == "tenant/baileys/primary.json"
    assert options[:region] == "sa-east-1"
    assert options[:scheme] == "http://"
    assert options[:http_client] == ExAws.Request.Req
  end

  test "put is atomic and creates with If-None-Match" do
    response = fn
      %{http_method: :head} -> {:error, {:http_error, 404, %{}}}
      %{http_method: :put} -> {:ok, %{headers: [{"etag", ~s("version-1")}]}}
    end

    assert {:ok, state} = state(response)
    assert :ok = S3.put(state, "primary", "json-body")

    assert_receive {:s3_request, %{http_method: :head}, _options}
    assert_receive {:s3_request, operation, _options}
    assert operation.http_method == :put
    assert operation.path == "baileys/primary.json"
    assert operation.body == "json-body"
    assert operation.headers["content-type"] == "application/json"
    assert operation.headers["if-none-match"] == "*"
  end

  test "updates and deletes use If-Match with the observed ETag" do
    etag = ~s("version-1")

    response = fn
      %{http_method: :get} -> {:ok, %{body: "old", headers: [{"etag", etag}]}}
      %{http_method: :put} -> {:ok, %{headers: [{"etag", ~s("version-2")}]}}
      %{http_method: :delete} -> {:ok, %{status_code: 204}}
    end

    assert {:ok, state} = state(response)
    assert {:ok, "old"} = S3.fetch(state, "primary")
    assert :ok = S3.put(state, "primary", "new")

    assert_receive {:s3_request, %{http_method: :get}, _options}
    assert_receive {:s3_request, put, _options}
    assert put.headers["if-match"] == etag

    assert :ok = S3.delete(state, "primary")
    assert_receive {:s3_request, delete, _options}
    assert delete.http_method == :delete
    assert delete.headers["if-match"] == ~s("version-2")
  end

  test "returns explicit conflicts and never retries with an unconditional write" do
    response = fn
      %{http_method: :get} ->
        {:ok, %{body: "old", headers: [{"etag", ~s("version-1")}]}}

      %{http_method: :put} ->
        {:error, {:http_error, 412, %{body: "precondition failed"}}}
    end

    assert {:ok, existing} = state(response)
    assert {:ok, "old"} = S3.fetch(existing, "primary")
    assert {:error, :conflict} = S3.put(existing, "primary", "new")

    assert_receive {:s3_request, %{http_method: :get}, _options}
    assert_receive {:s3_request, put, _options}
    assert put.headers["if-match"] == ~s("version-1")
    refute Map.has_key?(put.headers, "if-none-match")

    create_response = fn
      %{http_method: :get} -> {:error, {:http_error, 404, %{}}}
      %{http_method: :put} -> {:error, {:http_error, 409, %{}}}
    end

    assert {:ok, missing} = state(create_response)
    assert :not_found = S3.fetch(missing, "new")
    assert {:error, :conflict} = S3.put(missing, "new", "payload")

    assert_receive {:s3_request, %{http_method: :get}, _options}
    assert_receive {:s3_request, create, _options}
    assert create.headers["if-none-match"] == "*"
    refute Map.has_key?(create.headers, "if-match")
  end

  test "requires ETags instead of falling back to unsafe writes" do
    assert {:ok, state} = state({:ok, %{body: "payload", headers: []}})
    assert {:error, {:s3, :missing_etag}} = S3.fetch(state, "primary")
  end

  test "maps missing objects but preserves authorization and write failures" do
    assert {:ok, missing} = state({:error, {:http_error, 404, %{body: "missing"}}})
    assert :not_found = S3.fetch(missing, "primary")
    assert :ok = S3.delete(missing, "primary")
    refute_receive {:s3_request, %{http_method: :delete}, _options}

    assert {:ok, no_such_key} = state({:error, {:aws_error, %{code: "NoSuchKey"}}})
    assert :not_found = S3.fetch(no_such_key, "primary")

    forbidden = {:http_error, 403, %{body: "denied"}}
    assert {:ok, denied} = state({:error, forbidden})
    assert {:error, {:s3, ^forbidden}} = S3.fetch(denied, "primary")

    failure = {:timeout, :connect}

    failed_response = fn
      %{http_method: :head} -> {:error, {:http_error, 404, %{}}}
      %{http_method: :put} -> {:error, failure}
    end

    assert {:ok, failed} = state(failed_response)
    assert {:error, {:s3, ^failure}} = S3.put(failed, "primary", "payload")
  end

  test "delete propagates service and conflict errors" do
    etag = ~s("version-1")
    failure = {:http_error, 500, %{body: "error"}}

    failed_response = fn
      %{http_method: :get} -> {:ok, %{body: "payload", headers: [{"etag", etag}]}}
      %{http_method: :delete} -> {:error, failure}
    end

    assert {:ok, failed} = state(failed_response)
    assert {:ok, "payload"} = S3.fetch(failed, "primary")
    assert {:error, {:s3, ^failure}} = S3.delete(failed, "primary")

    conflict_response = fn
      %{http_method: :get} -> {:ok, %{body: "payload", headers: [{"etag", etag}]}}
      %{http_method: :delete} -> {:error, {:http_error, 412, %{}}}
    end

    assert {:ok, conflicted} = state(conflict_response)
    assert {:ok, "payload"} = S3.fetch(conflicted, "primary")
    assert {:error, :conflict} = S3.delete(conflicted, "primary")
  end

  test "encrypts before upload and decrypts after download" do
    key = :crypto.strong_rand_bytes(32)

    upload_response = fn
      %{http_method: :head} -> {:error, {:http_error, 404, %{}}}
      %{http_method: :put} -> {:ok, %{headers: [{"etag", ~s("encrypted-1")}]}}
    end

    encryption = {AESGCM, key: key}
    assert {:ok, upload} = state(upload_response, encryption: encryption)
    assert :ok = S3.put(upload, "primary", "secret-json")

    assert_receive {:s3_request, %{http_method: :head}, _options}
    assert_receive {:s3_request, operation, _options}
    refute operation.body == "secret-json"
    refute String.contains?(operation.body, "secret-json")
    assert operation.headers["content-type"] == "application/octet-stream"

    download_response =
      {:ok, %{body: operation.body, headers: [{"etag", ~s("encrypted-1")}]}}

    assert {:ok, download} = state(download_response, encryption: encryption)
    assert {:ok, "secret-json"} = S3.fetch(download, "primary")

    assert {:ok, wrong_key} =
             state(download_response, encryption: {AESGCM, key: :crypto.strong_rand_bytes(32)})

    assert {:error, {:encryption, :decryption_failed}} =
             S3.fetch(wrong_key, "primary")
  end

  defp state(response, options \\ []) do
    ex_aws_options = [owner: self(), response: response, scheme: "http://"]

    S3.init(
      [
        bucket: "sessions",
        region: "sa-east-1",
        requester: Requester,
        ex_aws_options: ex_aws_options
      ] ++ options
    )
  end
end
