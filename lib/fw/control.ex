defmodule FW.Control do
  @moduledoc """
  Dispatches incoming IPC requests.
  """

  use GenServer

  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def dispatch(request) when is_map(request) do
    GenServer.call(__MODULE__, {:dispatch, request}, 15_000)
  end

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call({:dispatch, request}, _from, state) do
    {:reply, route(request), state}
  end

  defp route(%{"command" => "ping"}) do
    %{status: "ok", data: %{message: "pong"}}
  end

  defp route(%{"command" => "status"}) do
    settings = FW.Settings.get()

    %{
      status: "ok",
      data: %{
        daemon: settings.daemon,
        log_level: settings.log_level,
        wallpaper: settings.wallpaper,
        monitors: settings.monitors,
        renderer: settings.renderer,
        port: FW.PortServer.status()
      }
    }
  end

  defp route(%{"command" => "stop"}) do
    Task.start(fn ->
      Process.sleep(50)
      System.stop(0)
    end)

    %{status: "ok", data: %{message: "daemon stopping"}}
  end

  defp route(%{"command" => "config", "payload" => %{"level" => level}}) do
    case normalize_level(level) do
      {:ok, normalized} ->
        FW.Settings.set_log_level(normalized)
        %{status: "ok", data: %{log_level: normalized}}

      {:error, reason} -> error(reason)
    end
  end

  defp route(%{"command" => "apply", "payload" => payload}) do
    case FW.PortServer.request("apply", payload) do
      {:ok, %{"status" => "ok"} = renderer_reply} ->
        updated = FW.Settings.update(%{wallpaper: payload})
        %{status: "ok", data: %{settings: updated, renderer: renderer_reply}}

      {:ok, %{"status" => "error", "message" => message} = renderer_reply} ->
        Logger.error("renderer apply rejected: #{message}")
        %{status: "error", error: message, renderer: renderer_reply}

      {:ok, renderer_reply} ->
        Logger.error("renderer apply returned unexpected payload: #{inspect(renderer_reply)}")
        %{status: "error", error: "renderer returned invalid response", renderer: renderer_reply}

      {:error, reason} ->
        Logger.error("renderer apply failed: #{inspect(reason)}")
        %{status: "error", error: inspect(reason)}
    end
  end

  defp route(%{"command" => other}) do
    error("unsupported command: #{other}")
  end

  defp route(_request) do
    error("invalid request")
  end

  defp error(reason) do
    %{status: "error", error: reason}
  end

  defp normalize_level(level) when level in ["debug", "info", "warn", "error"] do
    {:ok, level}
  end

  defp normalize_level(level), do: {:error, "unsupported log level: #{level}"}
end