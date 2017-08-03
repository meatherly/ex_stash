defmodule ExStash do
  require Logger

  def accept(port) do
    {:ok, socket} = :gen_tcp.listen(port,
                      [:binary, packet: :raw, active: false, reuseaddr: true])
    Logger.info "Accepting connections on port #{port}"
    loop_acceptor(socket)
  end

  defp loop_acceptor(socket) do
    {:ok, client} = :gen_tcp.accept(socket)
    {:ok, pid} = Task.Supervisor.start_child(ExStash.TaskSupervisor, fn -> serve(client) end)
    :ok = :gen_tcp.controlling_process(client, pid)
    loop_acceptor(socket)
  end

  defp serve(socket) do
    case socket |> :gen_tcp.recv(0) do
      {:ok, <<"2" :: utf8, 
              "W" :: utf8, 
              window_size :: size(32), 
              "2" :: utf8, 
              "C" :: utf8,
              empty4 :: size(32),
              data :: binary>>} ->
        Logger.info(inspect(window_size))
        Logger.info(inspect(empty4))
        Logger.info(inspect(data))
        {:ok, file} = File.open "packets.log", [:append]
        :ok = IO.binwrite(file, decompress_payload(data, socket) |> Poison.Parser.parse! |> Poison.encode!(pretty: true))
        :ok = File.close(file)
        serve(socket)
      {:ok, <<header :: utf8, frame_type :: utf8, data :: binary>>} ->
        Logger.info(inspect(header))
        Logger.info(inspect(frame_type))
        Logger.info(inspect(data))
        serve(socket)
      {:error, :closed} ->
        Logger.info("socket closed")
      error ->
        Logger.error("something bad happened when reading socket")
        Logger.error(inspect(error))
    end
    
  end

  defp send_ack(socket, seq) do
    :gen_tcp.send(socket, <<"2","A", seq>>)
  end

  def decompress_payload(payload, socket) do
    case payload do
      <<"2" :: utf8, "J" :: utf8, data :: binary >> ->
        Logger.info "data not compressed"
        parse_payload(payload, [], socket)
      _ ->
        zlibStream = :zlib.open()
        :ok = :zlib.inflateInit(zlibStream)
        uncompressed_payload = :zlib.inflate(zlibStream, payload)
        Logger.info("uncompressed_payload #{inspect(uncompressed_payload)}")
        :zlib.close(zlibStream)
        parse_payload(uncompressed_payload, "", socket)
    end   
  end

  def parse_payload([<<"2" :: utf8, "J", seq :: size(32), payload_length :: size(32), payload :: binary - size(payload_length), chunks :: binary>>], result, socket) do
    Logger.info("payload #{inspect(payload)}")
    Logger.info("chunks #{inspect(chunks)}")
    send_ack(socket, seq)
    parse_payload(chunks, result <> payload, socket)
  end

  def parse_payload(<<"2" :: utf8, "J", seq :: size(32), payload_length :: size(32), payload :: binary - size(payload_length), chunks :: binary>>, result, socket) do
    Logger.info("payload #{inspect(payload)}")
    Logger.info("chunks #{inspect(chunks)}")
    send_ack(socket, seq)
    parse_payload(chunks, result <> payload, socket)
  end

  def parse_payload("", result, socket) do
    result
  end
end
