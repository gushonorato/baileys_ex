defmodule Baileys.Media.Download do
  @moduledoc false

  @host "mmg.whatsapp.net"
  @max_bytes 64 * 1024 * 1024

  def get(path, options \\ [])

  def get(path, options) when is_binary(path) and is_list(options) do
    timeout = Keyword.get(options, :timeout, 30_000)
    max_bytes = Keyword.get(options, :max_bytes, @max_bytes)

    with true <- String.starts_with?(path, "/") || {:error, :invalid_media_path},
         {:ok, conn} <-
           Mint.HTTP.connect(:https, @host, 443,
             protocols: [:http1],
             transport_opts: [
               cacertfile: CAStore.file_path(),
               server_name_indication: ~c"mmg.whatsapp.net"
             ]
           ),
         {:ok, conn, request_ref} <-
           Mint.HTTP.request(conn, "GET", path, [{"origin", "https://web.whatsapp.com"}], nil) do
      receive_response(conn, request_ref, timeout, max_bytes, nil, [])
    else
      false -> {:error, :invalid_media_path}
      {:error, _reason} = error -> error
      {:error, _conn, reason} -> {:error, reason}
    end
  end

  def get(_path, _options), do: {:error, :invalid_media_path}

  defp receive_response(conn, request_ref, timeout, max_bytes, status, chunks) do
    receive do
      message ->
        case Mint.HTTP.stream(conn, message) do
          :unknown ->
            receive_response(conn, request_ref, timeout, max_bytes, status, chunks)

          {:ok, conn, responses} ->
            process_responses(conn, request_ref, responses, timeout, max_bytes, status, chunks)

          {:error, conn, reason, _responses} ->
            close(conn, {:error, reason})
        end
    after
      timeout -> close(conn, {:error, :media_download_timeout})
    end
  end

  defp process_responses(conn, request_ref, responses, timeout, max_bytes, status, chunks) do
    Enum.reduce_while(responses, {:continue, conn, status, chunks}, fn
      {:status, ^request_ref, status}, {:continue, conn, _status, chunks} ->
        {:cont, {:continue, conn, status, chunks}}

      {:headers, ^request_ref, _headers}, accumulator ->
        {:cont, accumulator}

      {:data, ^request_ref, data}, {:continue, conn, status, chunks} ->
        size = byte_size(data) + Enum.reduce(chunks, 0, &(byte_size(&1) + &2))

        if size <= max_bytes,
          do: {:cont, {:continue, conn, status, [data | chunks]}},
          else: {:halt, {:done, close(conn, {:error, :media_too_large})}}

      {:done, ^request_ref}, {:continue, conn, status, chunks} ->
        result =
          if status in 200..299,
            do: {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()},
            else: {:error, {:media_http_status, status}}

        {:halt, {:done, close(conn, result)}}

      _response, accumulator ->
        {:cont, accumulator}
    end)
    |> case do
      {:continue, conn, status, chunks} ->
        receive_response(conn, request_ref, timeout, max_bytes, status, chunks)

      {:done, result} ->
        result
    end
  end

  defp close(conn, result) do
    Mint.HTTP.close(conn)
    result
  end
end
