defmodule Mix.Tasks.Compile.FwRenderer do
  use Mix.Task.Compiler

  @shortdoc "Builds the C renderer binary"

  @impl true
  def run(_args) do
    source = Path.expand("c_src/fw_renderer.c")
    output = Path.expand("priv/fw_renderer")

    with true <- File.exists?(source),
         :ok <- File.mkdir_p(Path.dirname(output)),
         {:ok, compiler} <- find_compiler(),
         {output_text, 0} <- System.cmd(compiler, ["-O2", "-Wall", "-Wextra", source, "-o", output], stderr_to_stdout: true) do
      if String.trim(output_text) != "" do
        Mix.shell().info(output_text)
      end

      {:ok, []}
    else
      false -> {:error, ["missing C renderer source: #{source}"]}
      {:error, reason} -> {:error, [reason]}
      {output_text, code} -> {:error, ["#{String.trim(output_text)} (exit #{code})"]}
    end
  end

  defp find_compiler do
    case Enum.find(["cc", "clang", "gcc"], &System.find_executable/1) do
      nil -> {:error, "no C compiler found (cc/clang/gcc)"}
      compiler -> {:ok, compiler}
    end
  end
end