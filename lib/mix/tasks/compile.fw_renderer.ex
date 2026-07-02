defmodule Mix.Tasks.Compile.FwRenderer do
  use Mix.Task.Compiler
  @shortdoc "Builds the C renderer binary"
  @impl true
  def run(_args) do
    source = Path.expand("c_src/fw_renderer.c")
    protocol_xml = Path.expand("c_src/protocols/wlr-layer-shell-unstable-v1.xml")
    xdg_shell_xml = Path.expand("c_src/protocols/xdg-shell.xml")
    output = Path.expand("priv/fw_renderer")
    build_dir = Path.expand("_build/fw_renderer")
    protocol_header = Path.join(build_dir, "wlr-layer-shell-unstable-v1-client-protocol.h")
    protocol_code = Path.join(build_dir, "wlr-layer-shell-unstable-v1-protocol.c")
    xdg_shell_header = Path.join(build_dir, "xdg-shell-client-protocol.h")
    xdg_shell_code = Path.join(build_dir, "xdg-shell-protocol.c")

    with true <- File.exists?(source),
         true <- File.exists?(protocol_xml),
         true <- File.exists?(xdg_shell_xml),
         :ok <- File.mkdir_p(Path.dirname(output)),
         :ok <- File.mkdir_p(build_dir),
         {:ok, scanner} <- find_scanner(),
         {:ok, compiler} <- find_compiler(),
         {_, 0} <- System.cmd(scanner, ["client-header", xdg_shell_xml, xdg_shell_header], stderr_to_stdout: true),
         {_, 0} <- System.cmd(scanner, ["private-code", xdg_shell_xml, xdg_shell_code], stderr_to_stdout: true),
         {_, 0} <- System.cmd(scanner, ["client-header", protocol_xml, protocol_header], stderr_to_stdout: true),
         {_, 0} <- System.cmd(scanner, ["private-code", protocol_xml, protocol_code], stderr_to_stdout: true),
         {output_text, 0} <- System.cmd(compiler, compile_args(build_dir, source, [protocol_code, xdg_shell_code], output), stderr_to_stdout: true) do
      if String.trim(output_text) != "" do
        Mix.shell().info(output_text)
      end
      {:ok, []}
    else
      false -> {:error, ["missing build input for fw renderer"]}
      {:error, reason} -> {:error, [reason]}
      {output_text, code} ->
        IO.puts(:stderr, "fw_renderer build failed (exit #{code}):\n#{output_text}")
        {:error, ["fw renderer build failed (exit #{code})"]}
    end
  end

  defp compile_args(build_dir, source, protocol_sources, output) do
    cflags = pkg_config(["--cflags", "wayland-client", "gdk-pixbuf-2.0", "cairo"])
    libs = pkg_config(["--libs", "wayland-client", "gdk-pixbuf-2.0", "cairo"])
    ["-std=c11", "-O2", "-Wall", "-Wextra", "-Wno-unused-parameter", "-I#{build_dir}"] ++
      cflags ++ [source] ++ protocol_sources ++ ["-o", output] ++ libs
  end

  defp pkg_config(args) do
    {output, 0} = System.cmd("pkg-config", args, stderr_to_stdout: true)
    output
    |> String.trim()
    |> String.split(~r/\s+/, trim: true)
  end

  defp find_scanner do
    case System.find_executable("wayland-scanner") do
      nil -> {:error, "no wayland-scanner found"}
      scanner -> {:ok, scanner}
    end
  end

  defp find_compiler do
    case Enum.find(["cc", "clang", "gcc"], &System.find_executable/1) do
      nil -> {:error, "no C compiler found (cc/clang/gcc)"}
      compiler -> {:ok, compiler}
    end
  end
end