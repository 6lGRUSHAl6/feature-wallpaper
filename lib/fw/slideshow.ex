defmodule FW.Slideshow do
  @moduledoc """
  Runs a directory-based wallpaper slideshow.

  There is exactly one slideshow running at a time, so this is a singleton
  GenServer (name: __MODULE__), same pattern as `FW.Settings`/`FW.Control`.
  On `start/1` it applies the first image immediately, then swaps to the
  next one every `interval_ms` until `stop/0` is called or `start/1` is
  called again with a different directory.

  Applying an image goes through `FW.Control.apply_wallpaper/1` — the exact
  same path used by a plain `fw apply <path>` and by the startup
  wallpaper-restore logic in `FW.Control` — so a single tick failing (e.g. a
  file was deleted mid-slideshow) is handled identically to any other apply
  failure, and the currently-shown image is always reflected in
  `Settings`' `"wallpaper"` key regardless of how it got there.

  Slideshow configuration (directory, interval, shuffle, scaling,
  transition, and whether it was running) is persisted to `FW.Settings`
  under the `"slideshow"` key on every state change, and restored on daemon
  boot the same way `FW.Control` restores the last static wallpaper: by
  retrying for a few seconds, since the renderer port may not be up yet.
  """

  use GenServer

  require Logger

  @image_extensions ~w(.jpg .jpeg .png .webp .bmp .gif .avif .ico .svg .tif .tiff .jxl)
  @restore_retry_interval_ms 1_000
  @restore_max_attempts 15

  defstruct timer: nil,
            dir: nil,
            images: [],
            index: 0,
            interval_ms: nil,
            shuffle: false,
            scaling: nil,
            transition: nil,
            active: false

  ## Public API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Starts (or replaces) the running slideshow.

  `opts` is a string-keyed map as built by `FW.CLI.parse_payload/2`'s
  `--dir` branch:

      %{"dir" => path, "interval_ms" => pos_integer, "shuffle" => bool,
        "scaling" => string | nil, "transition" => string | nil}

  Returns `{:ok, status_map}` on success (see `status/0` for the shape) or
  `{:error, reason}` — e.g. the directory doesn't exist, isn't readable, or
  contains no supported images. A rejected `start/1` never disturbs a
  slideshow that was already running.
  """
  def start(opts) when is_map(opts) do
    GenServer.call(__MODULE__, {:start, opts}, 15_000)
  end

  @doc "Stops the running slideshow, if any. Idempotent."
  def stop do
    GenServer.call(__MODULE__, :stop)
  end

  @doc "Returns the current slideshow status."
  def status do
    GenServer.call(__MODULE__, :status)
  end

  ## GenServer callbacks

  @impl true
  def init(_) do
    Process.send_after(self(), {:restore, 1}, @restore_retry_interval_ms)
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:start, opts}, _from, state) do
    case do_start(opts, state) do
      {:ok, new_state} -> {:reply, {:ok, describe(new_state)}, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:stop, _from, state) do
    cancel_timer(state.timer)
    persist_stopped()
    {:reply, :ok, %__MODULE__{}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, describe(state), state}
  end

  @impl true
  def handle_info(:tick, %{images: images} = state) when images != [] do
    next_index = rem(state.index + 1, length(images))
    new_state = %{state | index: next_index, timer: schedule_tick(state.interval_ms)}

    case apply_current(new_state) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("slideshow: failed to apply next image: #{inspect(reason)}")
    end

    {:noreply, new_state}
  end

  # Defensive: a stray :tick with no images left (e.g. the whole directory
  # was emptied out from under us) should never crash the daemon.
  def handle_info(:tick, state), do: {:noreply, state}

  @impl true
  def handle_info({:restore, attempt}, state) do
    case FW.Settings.get()["slideshow"] do
      %{"active" => true} = saved ->
        case do_start(restore_opts(saved), state) do
          {:ok, new_state} ->
            Logger.info("restored slideshow from last session: #{saved["dir"]}")
            {:noreply, new_state}

          {:error, reason} when attempt < @restore_max_attempts ->
            Logger.debug(
              "slideshow restore attempt #{attempt} failed (#{inspect(reason)}), retrying"
            )

            Process.send_after(self(), {:restore, attempt + 1}, @restore_retry_interval_ms)
            {:noreply, state}

          {:error, reason} ->
            Logger.warning(
              "giving up restoring slideshow after #{@restore_max_attempts} attempts: #{inspect(reason)}"
            )

            {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  ## Internals

  defp restore_opts(saved) do
    %{
      "dir" => saved["dir"],
      "interval_ms" => saved["interval_ms"],
      "shuffle" => saved["shuffle"],
      "scaling" => saved["scaling"],
      "transition" => saved["transition"]
    }
  end

  # The single entry point for starting a slideshow, used by both the
  # {:start, opts} call and the boot-time restore path, so validation,
  # persistence, and the first apply are never duplicated between them.
  defp do_start(opts, state) do
    with {:ok, dir} <- validate_dir(opts["dir"]),
         {:ok, images} <- list_images(dir),
         :ok <- ensure_nonempty(images, dir),
         {:ok, interval_ms} <- validate_interval(opts["interval_ms"]) do
      cancel_timer(state.timer)

      new_state = %__MODULE__{
        dir: dir,
        images: maybe_shuffle(images, opts["shuffle"]),
        index: 0,
        interval_ms: interval_ms,
        shuffle: !!opts["shuffle"],
        scaling: opts["scaling"],
        transition: opts["transition"],
        active: true
      }

      case apply_current(new_state) do
        :ok ->
          new_state = %{new_state | timer: schedule_tick(interval_ms)}
          persist(new_state)
          {:ok, new_state}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp validate_dir(dir) when is_binary(dir) and dir != "", do: {:ok, dir}

  defp validate_dir(other),
    do: {:error, "missing or invalid slideshow directory: #{inspect(other)}"}

  defp validate_interval(ms) when is_integer(ms) and ms > 0, do: {:ok, ms}

  defp validate_interval(other),
    do: {:error, "missing or invalid slideshow interval_ms: #{inspect(other)}"}

  defp ensure_nonempty([], dir), do: {:error, "no supported images found in #{dir}"}
  defp ensure_nonempty(_images, _dir), do: :ok

  defp list_images(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        images =
          entries
          |> Enum.filter(&supported_image?/1)
          |> Enum.sort()
          |> Enum.map(&Path.join(dir, &1))

        {:ok, images}

      {:error, reason} ->
        {:error, "cannot read directory #{dir}: #{:file.format_error(reason)}"}
    end
  end

  defp supported_image?(filename) do
    ext = filename |> Path.extname() |> String.downcase()
    ext in @image_extensions
  end

  defp maybe_shuffle(images, true), do: Enum.shuffle(images)
  defp maybe_shuffle(images, _falsy), do: images

  defp apply_current(%{images: images, index: index} = state) do
    payload =
      %{"path" => Enum.at(images, index)}
      |> maybe_put("scaling", state.scaling)
      |> maybe_put("transition", state.transition)

    case apply_fun().(payload) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Indirection point for tests: talking to the real renderer requires a
  # live Wayland compositor (see FW.ControlTest's module doc for the same
  # constraint), which isn't available in CI. Overridable via
  # `config :fw, :slideshow_apply_fun, fun` — defaults to the real thing.
  defp apply_fun do
    Application.get_env(:fw, :slideshow_apply_fun, &FW.Control.apply_wallpaper/1)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp schedule_tick(interval_ms), do: Process.send_after(self(), :tick, interval_ms)

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  defp persist(state) do
    FW.Settings.update(%{
      "slideshow" => %{
        "active" => true,
        "dir" => state.dir,
        "interval_ms" => state.interval_ms,
        "shuffle" => state.shuffle,
        "scaling" => state.scaling,
        "transition" => state.transition
      }
    })
  end

  defp persist_stopped do
    FW.Settings.update(%{"slideshow" => %{"active" => false}})
  end

  defp describe(%__MODULE__{active: false}) do
    %{active: false}
  end

  defp describe(%__MODULE__{} = state) do
    %{
      active: true,
      dir: state.dir,
      interval_ms: state.interval_ms,
      shuffle: state.shuffle,
      scaling: state.scaling,
      transition: state.transition,
      image_count: length(state.images),
      current_index: state.index,
      current_path: Enum.at(state.images, state.index)
    }
  end
end
