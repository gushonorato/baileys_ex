defmodule Baileys.Store.S3 do
  @moduledoc """
  Amazon S3 credential storage using the standard ExAws credential chain.

  Writes and deletes use the ETag observed by the adapter as a precondition.
  Creating a missing session uses `If-None-Match: *`, so concurrent clients
  receive an explicit `:conflict` error instead of silently overwriting data.

  Adapter options do not accept AWS credentials directly. Configure credentials
  through ExAws and the AWS environment/provider chain.
  """

  @behaviour Baileys.Store.Adapter

  @default_prefix "baileys"

  @impl true
  def init(options) do
    with {:ok, bucket} <- required_string(options, :bucket),
         {:ok, region} <- required_string(options, :region),
         {:ok, prefix} <- prefix(options),
         {:ok, ex_aws_options} <- ex_aws_options(options),
         {:ok, requester} <- requester(options),
         {:ok, encryption} <- encryption(options),
         {:ok, versions} <- Agent.start_link(fn -> %{} end) do
      {:ok,
       %{
         bucket: bucket,
         region: region,
         prefix: prefix,
         ex_aws_options: ex_aws_options,
         requester: requester,
         encryption: encryption,
         versions: versions
       }}
    end
  end

  @impl true
  def fetch(state, session) do
    operation = ExAws.S3.get_object(state.bucket, object_key(state, session))

    case request(state, operation) do
      {:ok, %{body: body} = response} when is_binary(body) ->
        with {:ok, etag} <- response_etag(response),
             {:ok, payload} <- decrypt(state, session, body),
             :ok <- put_version(state, session, etag) do
          {:ok, payload}
        end

      {:error, reason} ->
        if not_found?(reason) do
          with :ok <- put_version(state, session, :missing), do: :not_found
        else
          s3_error(reason)
        end

      other ->
        s3_error({:unexpected_response, other})
    end
  end

  @impl true
  def put(state, session, payload) when is_binary(payload) do
    with {:ok, expected} <- ensure_version(state, session),
         {:ok, encrypted} <- encrypt(state, session, payload) do
      options =
        [content_type: content_type(state)]
        |> Keyword.merge(write_precondition(expected))

      operation =
        ExAws.S3.put_object(state.bucket, object_key(state, session), encrypted, options)

      case request(state, operation) do
        {:ok, response} ->
          with {:ok, etag} <- response_etag(response),
               :ok <- put_version(state, session, etag) do
            :ok
          end

        {:error, reason} ->
          request_error(reason)

        other ->
          s3_error({:unexpected_response, other})
      end
    end
  end

  @impl true
  def delete(state, session) do
    with {:ok, expected} <- ensure_version(state, session) do
      delete_version(state, session, expected)
    end
  end

  defp delete_version(_state, _session, :missing), do: :ok

  defp delete_version(state, session, etag) do
    operation = ExAws.S3.delete_object(state.bucket, object_key(state, session))
    operation = %{operation | headers: Map.put(operation.headers, "if-match", etag)}

    case request(state, operation) do
      {:ok, _response} -> put_version(state, session, :missing)
      {:error, reason} -> request_error(reason)
      other -> s3_error({:unexpected_response, other})
    end
  end

  defp ensure_version(state, session) do
    case get_version(state, session) do
      {:ok, :unknown} -> fetch_version(state, session)
      {:ok, version} -> {:ok, version}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_version(state, session) do
    operation = ExAws.S3.head_object(state.bucket, object_key(state, session))

    case request(state, operation) do
      {:ok, response} ->
        with {:ok, etag} <- response_etag(response),
             :ok <- put_version(state, session, etag) do
          {:ok, etag}
        end

      {:error, reason} ->
        if not_found?(reason) do
          with :ok <- put_version(state, session, :missing), do: {:ok, :missing}
        else
          s3_error(reason)
        end

      other ->
        s3_error({:unexpected_response, other})
    end
  end

  defp get_version(state, session) do
    case call_versions(state, fn versions -> Map.get(versions, session, :unknown) end) do
      {:error, {:s3, _reason}} = error -> error
      version -> {:ok, version}
    end
  end

  defp put_version(state, session, version) do
    case call_versions(
           state,
           fn versions -> {:ok, Map.put(versions, session, version)} end,
           :update
         ) do
      :ok -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp call_versions(state, function, mode \\ :get) do
    case mode do
      :get -> Agent.get(state.versions, function)
      :update -> Agent.get_and_update(state.versions, function)
    end
  catch
    :exit, _reason -> s3_error(:version_tracker_unavailable)
  end

  defp write_precondition(:missing), do: [if_none_match: "*"]
  defp write_precondition(etag), do: [if_match: etag]

  defp response_etag(%{headers: headers}) do
    case find_header(headers, "etag") do
      etag when is_binary(etag) and etag != "" -> {:ok, etag}
      _missing -> s3_error(:missing_etag)
    end
  end

  defp response_etag(_response), do: s3_error(:missing_etag)

  defp find_header(headers, name) when is_map(headers),
    do: find_header(Map.to_list(headers), name)

  defp find_header(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn
      {key, value} ->
        if String.downcase(to_string(key)) == name, do: normalize_header_value(value)

      _other ->
        nil
    end)
  end

  defp find_header(_headers, _name), do: nil
  defp normalize_header_value([value | _rest]) when is_binary(value), do: value
  defp normalize_header_value(value) when is_binary(value), do: value
  defp normalize_header_value(_value), do: nil

  defp encrypt(%{encryption: nil}, _session, payload), do: {:ok, payload}

  defp encrypt(state, session, payload) do
    invoke_encryption(state.encryption, :encrypt, [object_key(state, session), payload])
  end

  defp decrypt(%{encryption: nil}, _session, payload), do: {:ok, payload}

  defp decrypt(state, session, payload) do
    invoke_encryption(state.encryption, :decrypt, [object_key(state, session), payload])
  end

  defp invoke_encryption({module, encryption_state}, function, arguments) do
    case safe_apply(module, function, [encryption_state | arguments]) do
      {:ok, payload} when is_binary(payload) -> {:ok, payload}
      {:error, reason} -> encryption_error(reason)
      other -> encryption_error({:invalid_response, function, other})
    end
  end

  defp content_type(%{encryption: nil}), do: "application/json"
  defp content_type(_state), do: "application/octet-stream"

  defp request(state, operation) do
    options =
      Keyword.merge(state.ex_aws_options,
        region: state.region,
        http_client: ExAws.Request.Req
      )

    state.requester.request(operation, options)
  end

  defp object_key(state, session), do: state.prefix <> "/" <> session <> ".json"

  defp required_string(options, key) do
    case Keyword.fetch(options, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _value} -> {:error, String.to_atom("invalid_#{key}")}
      :error -> {:error, String.to_atom("#{key}_required")}
    end
  end

  defp prefix(options) do
    case Keyword.get(options, :prefix, @default_prefix) do
      value when is_binary(value) ->
        case String.trim(value, "/") do
          "" -> {:error, :invalid_prefix}
          prefix -> {:ok, prefix}
        end

      _value ->
        {:error, :invalid_prefix}
    end
  end

  defp ex_aws_options(options) do
    case Keyword.get(options, :ex_aws_options, []) do
      value when is_list(value) ->
        if Keyword.keyword?(value), do: {:ok, value}, else: {:error, :invalid_ex_aws_options}

      _value ->
        {:error, :invalid_ex_aws_options}
    end
  end

  defp requester(options) do
    case Keyword.get(options, :requester, ExAws) do
      module when is_atom(module) ->
        if Code.ensure_loaded?(module) and function_exported?(module, :request, 2),
          do: {:ok, module},
          else: {:error, :invalid_requester}

      _module ->
        {:error, :invalid_requester}
    end
  end

  defp encryption(options) do
    case Keyword.get(options, :encryption) do
      nil ->
        {:ok, nil}

      {module, encryption_options} when is_atom(module) and is_list(encryption_options) ->
        with true <- Keyword.keyword?(encryption_options),
             true <- valid_encryption_module?(module),
             {:ok, encryption_state} <- safe_apply(module, :init, [encryption_options]) do
          {:ok, {module, encryption_state}}
        else
          false -> {:error, :invalid_encryption}
          {:error, reason} -> encryption_error(reason)
          other -> encryption_error({:invalid_response, :init, other})
        end

      _other ->
        {:error, :invalid_encryption}
    end
  end

  defp valid_encryption_module?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :init, 1) and
      function_exported?(module, :encrypt, 3) and function_exported?(module, :decrypt, 3)
  end

  defp safe_apply(module, function, arguments) do
    apply(module, function, arguments)
  rescue
    error -> {:error, {:exception, error}}
  catch
    kind, reason -> {:error, {:exception, {kind, reason}}}
  end

  defp request_error(reason) do
    if conflict?(reason), do: {:error, :conflict}, else: s3_error(reason)
  end

  defp conflict?({:http_error, status, _response}) when status in [409, 412], do: true
  defp conflict?({:http_error, status, _headers, _body}) when status in [409, 412], do: true
  defp conflict?(%{status_code: status}) when status in [409, 412], do: true
  defp conflict?(%{"status_code" => status}) when status in [409, 412], do: true
  defp conflict?(%{code: code}), do: conflict_code?(code)
  defp conflict?(%{"Code" => code}), do: conflict_code?(code)
  defp conflict?({left, right}), do: conflict?(left) or conflict?(right)
  defp conflict?(values) when is_list(values), do: Enum.any?(values, &conflict?/1)
  defp conflict?(value), do: conflict_code?(value)

  defp conflict_code?(code), do: code in ["PreconditionFailed", "ConditionalRequestConflict"]

  defp not_found?({:http_error, 404, _response}), do: true
  defp not_found?({:http_error, 404, _headers, _body}), do: true
  defp not_found?(%{status_code: 404}), do: true
  defp not_found?(%{"status_code" => 404}), do: true
  defp not_found?(%{code: "NoSuchKey"}), do: true
  defp not_found?(%{"Code" => "NoSuchKey"}), do: true
  defp not_found?("NoSuchKey"), do: true
  defp not_found?({left, right}), do: not_found?(left) or not_found?(right)
  defp not_found?(values) when is_list(values), do: Enum.any?(values, &not_found?/1)
  defp not_found?(_reason), do: false

  defp encryption_error(reason), do: {:error, {:encryption, reason}}
  defp s3_error(reason), do: {:error, {:s3, reason}}
end
