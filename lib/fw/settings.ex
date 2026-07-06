defmodule FW.Settings do
  @moduledoc """
  Persistent runtime state for fw.

  All state is stored and manipulated with *string* keys throughout —
  matching what `FW.JSON.decode/1` always produces. This avoids the
  classic Elixir footgun where `%{path: x}` (atom key) and
  `%{"path" => x}` (string key) are treated as completely different map
  entries by `Map.merge/3`, which used to leave stale/duplicate keys
  behind after every `update/1` call from a JSON-decoded payload.
  """

  use GenServer

  require Logger

  @default_state %{
    "version" => 1,
    "daemon" => %{"host" => [127, 0, 0, 1], "port" => 47_788},
    "log_level" => "info",
    "renderer" => %{"binary" => "priv/fw_renderer"},
    "wallpaper" => %{"path" => nil, "scaling" => "fit", "transition" => "none"},
    "monitors" => [],
    "slideshow" => %{
      "active" => false,
      "dir" => nil,
      "interval_ms" => nil,
      "shuffle" => false,
      "scaling" => nil,
      "transition" => nil
    }
  }

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def get do
    GenServer.call(__MODULE__, :get)
  end

  @doc """
  Deep-merges `attrs` (string-keyed map, as produced by `FW.JSON.decode/1`)
  into the current state and persists the result.
  """
  def update(attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:update, stringify_keys(attrs)})
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
    updated = Map.put(state, "log_level", level)

    case safe_log_level_atom(level) do
      {:ok, atom} -> Logger.configure(level: atom)
      :error -> Logger.warning("unknown log level requested: #{level}")
    end

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

  # Only merges plain maps recursively; any other conflicting value type is
  # simply replaced by the right-hand side (last write wins).
  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge(left_value, right_value)
    end)
  end

  defp deep_merge(_left, right), do: right

  # Guarantees every key in `map` (and nested maps) is a string, regardless
  # of whether the caller built it with atom or string keys. This is what
  # prevents the atom/string duplicate-key bug from ever reappearing, even
  # if some future caller passes an atom-keyed map by mistake.
  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp normalize_state(%{} = decoded) do
    %{
      "version" => Map.get(decoded, "version", @default_state["version"]),
      "daemon" => normalize_daemon(Map.get(decoded, "daemon", %{})),
      "log_level" => Map.get(decoded, "log_level", @default_state["log_level"]),
      "renderer" => normalize_renderer(Map.get(decoded, "renderer", %{})),
      "wallpaper" => normalize_wallpaper(Map.get(decoded, "wallpaper", %{})),
      "monitors" => Map.get(decoded, "monitors", @default_state["monitors"]),
      "slideshow" => normalize_slideshow(Map.get(decoded, "slideshow", %{}))
    }
  end

  defp normalize_state(_invalid), do: @default_state

  defp normalize_daemon(%{} = daemon) do
    %{
      "host" => Map.get(daemon, "host", @default_state["daemon"]["host"]),
      "port" => Map.get(daemon, "port", @default_state["daemon"]["port"])
    }
  end

  defp normalize_renderer(%{} = renderer) do
    %{
      "binary" => Map.get(renderer, "binary", @default_state["renderer"]["binary"])
    }
  end

  defp normalize_wallpaper(%{} = wallpaper) do
    %{
      "path" => Map.get(wallpaper, "path", @default_state["wallpaper"]["path"]),
      "scaling" => Map.get(wallpaper, "scaling", @default_state["wallpaper"]["scaling"]),
      "transition" => Map.get(wallpaper, "transition", @default_state["wallpaper"]["transition"])
    }
  end

  # Every field defaults to nil/false rather than raising when absent, since
  # this also runs against whatever was last persisted to disk — a partial
  # or stale "slideshow" map here must never crash the daemon on boot.
  defp normalize_slideshow(%{} = slideshow) do
    %{
      "active" => Map.get(slideshow, "active", @default_state["slideshow"]["active"]),
      "dir" => Map.get(slideshow, "dir", @default_state["slideshow"]["dir"]),
      "interval_ms" =>
        Map.get(slideshow, "interval_ms", @default_state["slideshow"]["interval_ms"]),
      "shuffle" => Map.get(slideshow, "shuffle", @default_state["slideshow"]["shuffle"]),
      "scaling" => Map.get(slideshow, "scaling", @default_state["slideshow"]["scaling"]),
      "transition" => Map.get(slideshow, "transition", @default_state["slideshow"]["transition"])
    }
  end

  defp safe_log_level_atom(level) when level in ["debug", "info", "warn", "error"] do
    {:ok, String.to_existing_atom(level)}
  end

  defp safe_log_level_atom(_level), do: :error
end
