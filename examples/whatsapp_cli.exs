defmodule WhatsAppCLI.Handler do
  use Baileys

  @impl Baileys
  def init(owner), do: {:ok, owner}

  @impl Baileys
  def handle_event(%Baileys.Event{} = event, owner) do
    send(owner, {:whatsapp_event, event})
    {:noreply, owner}
  end
end

defmodule WhatsAppCLI do
  @sessions_root Path.expand("baileys_sessions", __DIR__)

  def run do
    Process.flag(:trap_exit, true)

    IO.puts("""
    WhatsApp CLI
    /chat <phone>  seleciona uma conversa
    /help          mostra os comandos
    /quit          encerra o cliente
    """)

    case Baileys.start_link(WhatsAppCLI.Handler, self(),
           session: "whatsapp_cli",
           store: {Baileys.Store.File, root: @sessions_root}
         ) do
      {:ok, server} ->
        loop(%{server: server, reader: nil, active_chat: nil, online?: false})

      {:error, reason} ->
        IO.puts(:stderr, "Nao foi possivel iniciar: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp loop(state) do
    state = ensure_reader(state)
    reader_reference = if state.reader, do: state.reader.ref

    receive do
      {:whatsapp_event, event} ->
        state
        |> handle_event(event)
        |> loop()

      {reference, line} when is_reference(reference) and reference == reader_reference ->
        Process.demonitor(reference, [:flush])

        state
        |> Map.put(:reader, nil)
        |> handle_input(line)

      {:DOWN, reference, :process, _pid, reason}
      when is_reference(reference) and reference == reader_reference ->
        IO.puts(:stderr, "Leitura do terminal encerrou: #{inspect(reason)}")
        stop(state)

      {:EXIT, server, reason} when server == state.server ->
        shutdown_reader(state.reader)

        if reason not in [:normal, :shutdown] do
          IO.puts(:stderr, "Cliente encerrou: #{inspect(reason)}")
          System.halt(1)
        end
    end
  end

  defp handle_event(state, %Baileys.Event{type: :qr, data: %Baileys.QR{} = qr}) do
    print_event(state, "Escaneie o QR em WhatsApp > Aparelhos conectados:")
    render_qr(qr.payload)
    state
  end

  defp handle_event(state, %Baileys.Event{type: :connection, data: %{state: :online}}) do
    print_event(state, "Conectado. Use /chat <phone> para iniciar uma conversa.")
    %{state | online?: true}
  end

  defp handle_event(state, %Baileys.Event{type: :connection, data: connection}) do
    print_event(state, "Conexao: #{connection.state}")
    %{state | online?: false}
  end

  defp handle_event(state, %Baileys.Event{type: :paired, data: account}) do
    print_event(state, "Pareado como #{account.jid || "desconhecido"}; reconectando...")
    state
  end

  defp handle_event(state, %Baileys.Event{type: :text_message, data: message}) do
    direction = if message.from_me, do: "voce ->", else: "<-"
    print_event(state, "[#{direction} #{chat_label(message.chat_jid)}] #{message.text}")
    state
  end

  defp handle_event(state, %Baileys.Event{type: :message_status, data: status}) do
    if status.status in [:failed, :delivered, :read] do
      print_event(state, "[#{chat_label(status.to)}] mensagem #{status.status} (#{status.id})")
    end

    state
  end

  defp handle_event(state, %Baileys.Event{type: :disconnected, data: disconnected}) do
    print_event(state, "Desconectado: #{disconnected.reason}")
    %{state | online?: false}
  end

  defp handle_event(state, %Baileys.Event{type: :error, data: error}) do
    print_event(state, "Erro: #{error.message}", :stderr)
    state
  end

  defp handle_event(state, _event), do: state

  defp handle_input(state, :eof), do: stop(state)

  defp handle_input(state, {:error, reason}) do
    IO.puts(:stderr, "Erro ao ler terminal: #{inspect(reason)}")
    stop(state)
  end

  defp handle_input(state, line) when is_binary(line) do
    case String.trim(line) do
      "" ->
        loop(state)

      "/quit" ->
        stop(state)

      "/help" ->
        IO.puts("/chat <phone> seleciona o chat; /quit encerra; qualquer outro texto e enviado")
        loop(state)

      "/chat" ->
        IO.puts("Uso: /chat <phone>, incluindo o codigo do pais")
        loop(state)

      "/chat " <> phone ->
        select_chat(state, phone)

      "/" <> _unknown ->
        IO.puts("Comando desconhecido. Use /help.")
        loop(state)

      text ->
        send_text(state, text)
    end
  end

  defp select_chat(state, phone) do
    case Baileys.jid(String.trim(phone)) do
      {:ok, jid} ->
        IO.puts("Chat ativo: #{chat_label(jid)}")
        loop(%{state | active_chat: jid})

      {:error, _reason} ->
        IO.puts("Telefone invalido. Informe codigo do pais e DDD, por exemplo +5511999999999.")
        loop(state)
    end
  end

  defp send_text(%{active_chat: nil} = state, _text) do
    IO.puts("Nenhum chat selecionado. Use /chat <phone>.")
    loop(state)
  end

  defp send_text(state, text) do
    case Baileys.send_text(state.server, state.active_chat, text) do
      {:ok, message} ->
        IO.puts("[voce -> #{chat_label(message.to)}] #{text}")

      {:error, reason} ->
        IO.puts(:stderr, "Falha ao enviar: #{inspect(reason)}")
    end

    loop(state)
  end

  defp ensure_reader(%{online?: true, reader: nil} = state) do
    reader = Task.async(fn -> IO.gets(prompt(state.active_chat)) end)
    %{state | reader: reader}
  end

  defp ensure_reader(state), do: state

  defp prompt(nil), do: "whatsapp [sem chat]> "
  defp prompt(jid), do: "whatsapp [#{chat_label(jid)}]> "

  defp chat_label(jid) do
    case String.split(jid || "desconhecido", "@", parts: 2) do
      [user, "s.whatsapp.net"] -> "+" <> hd(String.split(user, ":", parts: 2))
      _other -> jid || "desconhecido"
    end
  end

  defp print_event(state, message, device \\ :stdio)

  defp print_event(%{reader: nil}, message, device), do: IO.puts(device, message)

  defp print_event(state, message, device) do
    IO.puts(device, "\n#{message}")
    IO.write(prompt(state.active_chat))
  end

  defp stop(state) do
    shutdown_reader(state.reader)
    if Process.alive?(state.server), do: GenServer.stop(state.server, :normal)
    :ok
  end

  defp shutdown_reader(nil), do: :ok
  defp shutdown_reader(reader), do: Task.shutdown(reader, :brutal_kill)

  defp render_qr(payload) do
    {:ok, qr} = QRCode.create(payload, :low)
    quiet_zone = List.duplicate(0, 2)
    width = length(qr.matrix) + 4
    blank = List.duplicate(0, width)

    matrix =
      [blank, blank] ++ Enum.map(qr.matrix, &(quiet_zone ++ &1 ++ quiet_zone)) ++ [blank, blank]

    matrix
    |> Enum.chunk_every(2, 2, [blank])
    |> Enum.each(fn [top, bottom] ->
      line =
        Enum.zip(top, bottom)
        |> Enum.map_join(fn
          {0, 0} -> " "
          {1, 0} -> "▀"
          {0, 1} -> "▄"
          {1, 1} -> "█"
        end)

      IO.puts(line)
    end)
  end
end

WhatsAppCLI.run()
