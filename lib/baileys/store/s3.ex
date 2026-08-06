defmodule Baileys.Store.S3 do
  @moduledoc """
  Amazon S3 credential storage using the standard ExAws credential chain.

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
         {:ok, requester} <- requester(options) do
      {:ok,
       %{
         bucket: bucket,
         region: region,
         prefix: prefix,
         ex_aws_options: ex_aws_options,
         requester: requester
       }}
    end
  end

  @impl true
  def fetch(state, session) do
    operation = ExAws.S3.get_object(state.bucket, object_key(state, session))

    case request(state, operation) do
      {:ok, %{body: body}} when is_binary(body) -> {:ok, body}
      {:error, reason} -> if not_found?(reason), do: :not_found, else: s3_error(reason)
      other -> s3_error({:unexpected_response, other})
    end
  end

  @impl true
  def put(state, session, payload) when is_binary(payload) do
    operation =
      ExAws.S3.put_object(state.bucket, object_key(state, session), payload,
        content_type: "application/json"
      )

    case request(state, operation) do
      {:ok, _response} -> :ok
      {:error, reason} -> s3_error(reason)
      other -> s3_error({:unexpected_response, other})
    end
  end

  @impl true
  def delete(state, session) do
    operation = ExAws.S3.delete_object(state.bucket, object_key(state, session))

    case request(state, operation) do
      {:ok, _response} -> :ok
      {:error, reason} -> if not_found?(reason), do: :ok, else: s3_error(reason)
      other -> s3_error({:unexpected_response, other})
    end
  end

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

  defp s3_error(reason), do: {:error, {:s3, reason}}
end
