defmodule Baileys.Store.S3Test.Requester do
  def request(operation, options) do
    send(Keyword.fetch!(options, :owner), {:s3_request, operation, options})
    Keyword.fetch!(options, :response)
  end
end

defmodule Baileys.Store.S3Test do
  use ExUnit.Case, async: true

  alias Baileys.Store.S3
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
  end

  test "fetch builds the deterministic key and forces the Req HTTP client" do
    assert {:ok, state} = state({:ok, %{body: "payload"}}, prefix: "/tenant/baileys/")
    assert {:ok, "payload"} = S3.fetch(state, "primary")

    assert_receive {:s3_request, operation, options}
    assert operation.http_method == :get
    assert operation.bucket == "sessions"
    assert operation.path == "tenant/baileys/primary.json"
    assert options[:region] == "sa-east-1"
    assert options[:scheme] == "http://"
    assert options[:http_client] == ExAws.Request.Req
  end

  test "put sends the JSON body and content type synchronously" do
    assert {:ok, state} = state({:ok, %{status_code: 200}})
    assert :ok = S3.put(state, "primary", "json-body")

    assert_receive {:s3_request, operation, _options}
    assert operation.http_method == :put
    assert operation.path == "baileys/primary.json"
    assert operation.body == "json-body"
    assert operation.headers["content-type"] == "application/json"
  end

  test "maps missing objects but preserves authorization and other failures" do
    assert {:ok, missing} = state({:error, {:http_error, 404, %{body: "missing"}}})
    assert :not_found = S3.fetch(missing, "primary")

    assert {:ok, no_such_key} = state({:error, {:aws_error, %{code: "NoSuchKey"}}})
    assert :not_found = S3.fetch(no_such_key, "primary")

    forbidden = {:http_error, 403, %{body: "denied"}}
    assert {:ok, denied} = state({:error, forbidden})
    assert {:error, {:s3, ^forbidden}} = S3.fetch(denied, "primary")

    failure = {:timeout, :connect}
    assert {:ok, failed} = state({:error, failure})
    assert {:error, {:s3, ^failure}} = S3.put(failed, "primary", "payload")
  end

  test "delete is idempotent for missing objects and propagates other errors" do
    assert {:ok, missing} = state({:error, {:http_error, 404, %{}}})
    assert :ok = S3.delete(missing, "primary")
    assert_receive {:s3_request, %{http_method: :delete}, _options}

    failure = {:http_error, 500, %{body: "error"}}
    assert {:ok, failed} = state({:error, failure})
    assert {:error, {:s3, ^failure}} = S3.delete(failed, "primary")
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
