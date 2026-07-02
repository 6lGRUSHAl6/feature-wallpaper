defmodule FW.Control do
  @moduledoc """
  Dispatches incoming IPC requests.
  """

  use GenServer

  require Logger

  @restore_retry_interval_ms 1_000
  @restore_max_attempts 15

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def dispatch(request) when is_map(request) do
    GenServer.call(__MODULE__, {:dispatch, request}, 15_000)
  end

  @impl true
  def init(state) do
    Process.send_after(self(), {:restore_wallpaper, 1}, @restore_retry_interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_call({:dispatch, request}, _from, state) do
    {:reply, route(request), state}
  end

  @impl true
  def handle_info({:restore_wallpaper, attempt}, state) do
    case FW.Settings.get()["wallpaper"] do
      %{"path" => path} when is_binary(path) and path != "" ->
        if File.exists?(path) do
          case apply_wallpaper(%{"path" => path} |> maybe_put_scaling(attempt) |> restore_payload()) do
            {:ok, _} ->
              Logger.info("restored wallpaper from last session: #{path}")

            {:error, reason} when attempt < @restore_max_attempts ->
              Logger.debug(
                "wallpaper restore attempt #{attempt} failed (#{inspect(reason)}), retrying"
              )

              Process.send_after(
                self(),
                {:restore_wallpaper, attempt + 1},
                @restore_retry_interval_ms
              )

            {:error, reason} ->
              Logger.warning(
                "giving up restoring wallpaper after #{@restore_max_attempts} attempts: #{inspect(reason)}"
              )
          end
        else
          Logger.debug("saved wallpaper path no longer exists, skipping restore: #{path}")
        end

      _ ->
        :ok
    end

    {:noreply, state}
  end

  @doc false
  def route(%{"command" => "ping"}) do
    %{status: "ok", data: %{message: "pong"}}
  end

  def route(%{"command" => "status"}) do
    settings = FW.Settings.get()

    %{
      status: "ok",
      data: %{
        daemon: settings["daemon"],
        log_level: settings["log_level"],
        wallpaper: settings["wallpaper"],
        monitors: settings["monitors"],
        renderer: settings["renderer"],
        port: FW.PortServer.status()
      }
    }
  end

  def route(%{"command" => "stop"}) do
    Task.start(fn ->
      Process.sleep(50)
      System.stop(0)
    end)

    %{status: "ok", data: %{message: "daemon stopping"}}
  end

  def route(%{"command" => "config", "payload" => %{"level" => level}}) do
    case normalize_level(level) do
      {:ok, normalized} ->
        FW.Settings.set_log_level(normalized)
        %{status: "ok", data: %{log_level: normalized}}

      {:error, reason} -> error(reason)
    end
  end

  def route(%{"command" => "apply", "payload" => %{"path" => path} = payload}) when is_binary(path) and path != "" do
    case apply_wallpaper(payload) do
      {:ok, %{settings: updated, renderer: renderer_reply}} ->
        %{status: "ok", data: %{settings: updated, renderer: renderer_reply}}

      {:error, {:rejected, message, renderer_reply}} ->
        %{status: "error", error: message, renderer: renderer_reply}

      {:error, {:invalid_response, renderer_reply}} ->
        %{status: "error", error: "renderer returned invalid response", renderer: renderer_reply}

      {:error, reason} ->
        %{status: "error", error: inspect(reason)}
    end
  end

  def route(%{"command" => "apply"}) do
    error("missing or empty 'path' in apply payload")
  end

  def route(%{"command" => other}) do
    error("unsupported command: #{other}")
  end

  def route(_request) do
    error("invalid request")
  end

  # Shared by the IPC "apply" command and the startup wallpaper-restore path,
  # so both go through identical validation/persistence logic.
  defp apply_wallpaper(payload) do
    case FW.PortServer.request("apply", payload) do
      {:ok, %{"status" => "ok"} = renderer_reply} ->
        updated = FW.Settings.update(%{"wallpaper" => payload})
        {:ok, %{settings: updated, renderer: renderer_reply}}

      {:ok, %{"status" => "error", "message" => message} = renderer_reply} ->
        Logger.error("renderer apply rejected: #{message}")
        {:error, {:rejected, message, renderer_reply}}

      {:ok, renderer_reply} ->
        Logger.error("renderer apply returned unexpected payload: #{inspect(renderer_reply)}")
        {:error, {:invalid_response, renderer_reply}}

      {:error, reason} ->
        Logger.error("renderer apply failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp restore_payload(%{"path" => _path} = base), do: base

  defp maybe_put_scaling(payload, _attempt) do
    case FW.Settings.get()["wallpaper"] do
      %{"scaling" => scaling} when is_binary(scaling) -> Map.put(payload, "scaling", scaling)
      _ -> payload
    end
    |> then(fn payload ->
      case FW.Settings.get()["wallpaper"] do
        %{"transition" => transition} when is_binary(transition) ->
          Map.put(payload, "transition", transition)

        _ ->
          payload
      end
    end)
  end

  defp error(reason) do
    %{status: "error", error: reason}
  end

  defp normalize_level(level) when level in ["debug", "info", "warn", "error"] do
    {:ok, level}
  end

  defp normalize_level(level), do: {:error, "unsupported log level: #{level}"}
end