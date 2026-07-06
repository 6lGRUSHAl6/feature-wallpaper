defmodule FW.IPC.Server do
  @moduledoc """
  TCP server that accepts JSON requests from the CLI.
  """

  use GenServer

  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)

    host = Application.get_env(:fw, :daemon_host, {127, 0, 0, 1})
    port = Application.get_env(:fw, :daemon_port, 47_788)

    {:ok, listen_socket} =
      :gen_tcp.listen(port, [:binary, packet: :line, active: false, reuseaddr: true, ip: host])

    acceptor = spawn_link(fn -> accept_loop(listen_socket) end)

    {:ok, %{listen_socket: listen_socket, acceptor: acceptor, host: host, port: port}}
  end

  @impl true
  def handle_info({:EXIT, _pid, reason}, state) do
    Logger.debug("ipc server child exited: #{inspect(reason)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listen_socket)
    :ok
  end

  defp accept_loop(listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        spawn_link(fn -> serve_client(socket) end)
        accept_loop(listen_socket)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.error("ipc accept failed: #{inspect(reason)}")
        accept_loop(listen_socket)
    end
  end

  defp serve_client(socket) do
    try do
      loop(socket)
    after
      :gen_tcp.close(socket)
    end
  end

  defp loop(socket) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, line} ->
        line
        |> String.trim()
        |> dispatch()
        |> send_reply(socket)

        loop(socket)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        send_reply(%{status: "error", error: inspect(reason)}, socket)
    end
  end

  defp dispatch(""), do: %{status: "error", error: "empty request"}

  defp dispatch(line) do
    case FW.JSON.decode(line) do
      {:ok, request} -> FW.Control.dispatch(request)
      {:error, reason} -> %{status: "error", error: inspect(reason), raw: line}
    end
  end

  defp send_reply(reply, socket) do
    :gen_tcp.send(socket, FW.JSON.encode!(reply) <> "\n")
  end
end
