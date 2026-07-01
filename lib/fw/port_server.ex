defmodule FW.PortServer do
  @moduledoc """
  Manages the fw_renderer port process.
  """

  use GenServer

  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def request(command, payload \\ %{}, timeout \\ 15_000) do
    GenServer.call(__MODULE__, {:request, command, payload}, timeout)
  end

  def status do
    GenServer.call(__MODULE__, :status)
  end

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)

    state = %{
      port: nil,
      buffer: "",
      pending: %{},
      binary: renderer_binary(),
      restart_count: 0
    }

    {:ok, open_port(state)}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, %{running: is_port(state.port), binary: state.binary}, state}
  end

  @impl true
  def handle_call({:request, _command, _payload}, _from, %{port: nil} = state) do
    {:reply, {:error, :renderer_not_running}, state}
  end

  @impl true
  def handle_call({:request, command, payload}, from, state) do
    id = Integer.to_string(System.unique_integer([:positive, :monotonic]))
    message = FW.JSON.encode!(%{id: id, command: command, payload: payload})
    Port.command(state.port, message <> "\n")

    {:noreply, %{state | pending: Map.put(state.pending, id, from)}}
  end

  @impl true
  def handle_info({port, {:data, chunk}}, %{port: port} = state) do
    {:noreply, consume_buffer(%{state | buffer: state.buffer <> chunk})}
  end

  @impl true
  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    Logger.error("renderer port exited: #{inspect(reason)}")
    reply_pending(state.pending, {:error, {:renderer_exit, reason}})
    {:noreply, restart_port(%{state | port: nil, pending: %{}, buffer: ""})}
  end

  @impl true
  def handle_info(_message, state) do
    {:noreply, state}
  end

  defp consume_buffer(%{buffer: buffer} = state) do
    case :binary.match(buffer, "\n") do
      {index, 1} ->
        line = binary_part(buffer, 0, index)
        rest = binary_part(buffer, index + 1, byte_size(buffer) - index - 1)
        consume_buffer(handle_line(line, %{state | buffer: rest}))

      :nomatch ->
        state
    end
  end

  defp handle_line("", state), do: state

  defp handle_line(line, state) do
    case FW.JSON.decode(line) do
      {:ok, %{"id" => id} = response} ->
        {from, pending} = Map.pop(state.pending, id)

        if from do
          GenServer.reply(from, {:ok, response})
        else
          Logger.debug("unexpected renderer response: #{inspect(response)}")
        end

        %{state | pending: pending}

      {:ok, response} ->
        Logger.debug("renderer response without id: #{inspect(response)}")
        state

      {:error, _} ->
        Logger.warning("renderer stderr: #{line}")
        state
    end
  end

  defp open_port(state) do
    case Port.open({:spawn_executable, state.binary}, [:binary, :exit_status, :use_stdio, :stderr_to_stdout]) do
      port when is_port(port) -> %{state | port: port}
    end
  end

  defp restart_port(state) do
    Process.sleep(min(250 * max(state.restart_count + 1, 1), 2_000))
    open_port(%{state | restart_count: state.restart_count + 1})
  end

  defp reply_pending(pending, reason) do
    Enum.each(pending, fn {_id, from} -> GenServer.reply(from, reason) end)
  end

  defp renderer_binary do
    Application.app_dir(:fw, Application.get_env(:fw, :renderer_binary))
  end
end