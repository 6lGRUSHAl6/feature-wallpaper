defmodule FW.Settings do
  @moduledoc """
  Persistent runtime state for fw.
  """

  use GenServer

  @default_state %{
    version: 1,
    daemon: %{host: [127, 0, 0, 1], port: 47_788},
    log_level: "info",
    renderer: %{binary: "priv/fw_renderer"},
    wallpaper: %{path: nil, scaling: "fit", transition: "none"},
    monitors: []
  }

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def get do
    GenServer.call(__MODULE__, :get)
  end

  def update(attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:update, attrs})
  end

  def set_log_level(level) when is_binary(level) do
    GenServer.call(__MODULE__, {:set_log_level, level})
  end

  @impl true
  def init(_) do
    {:ok, load_state()}
  end

  @impl true
  def handle_call(:get, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:update, attrs}, _from, state) do
    updated = deep_merge(state, attrs)
    persist(updated)
    {:reply, updated, updated}
  end

  @impl true
  def handle_call({:set_log_level, level}, _from, state) do
    updated = Map.put(state, :log_level, level)
    Logger.configure(level: String.to_existing_atom(level))
    persist(updated)
    {:reply, updated, updated}
  end

  defp load_state do
    path = state_file()

    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- FW.JSON.decode(body) do
      normalize_state(decoded)
    else
      _ -> @default_state
    end
  end

  defp persist(state) do
    path = state_file()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, FW.JSON.encode!(state))
  end

  defp state_file do
    Application.app_dir(:fw, Application.get_env(:fw, :state_file))
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value -> deep_merge(left_value, right_value) end)
  end

  defp deep_merge(_left, right), do: right

  defp normalize_state(%{} = decoded) do
    %{
      version: Map.get(decoded, "version", @default_state.version),
      daemon: normalize_daemon(Map.get(decoded, "daemon", %{})),
      log_level: Map.get(decoded, "log_level", @default_state.log_level),
      renderer: normalize_renderer(Map.get(decoded, "renderer", %{})),
      wallpaper: normalize_wallpaper(Map.get(decoded, "wallpaper", %{})),
      monitors: Map.get(decoded, "monitors", @default_state.monitors)
    }
  end

  defp normalize_daemon(%{} = daemon) do
    %{
      host: Map.get(daemon, "host", @default_state.daemon.host),
      port: Map.get(daemon, "port", @default_state.daemon.port)
    }
  end

  defp normalize_renderer(%{} = renderer) do
    %{
      binary: Map.get(renderer, "binary", @default_state.renderer.binary)
    }
  end

  defp normalize_wallpaper(%{} = wallpaper) do
    %{
      path: Map.get(wallpaper, "path", @default_state.wallpaper.path),
      scaling: Map.get(wallpaper, "scaling", @default_state.wallpaper.scaling),
      transition: Map.get(wallpaper, "transition", @default_state.wallpaper.transition)
    }
  end
end