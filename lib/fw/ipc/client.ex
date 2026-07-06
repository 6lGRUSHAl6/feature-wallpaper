defmodule FW.IPC.Client do
  @moduledoc """
  TCP client used by the CLI to talk to the daemon.
  """

  def request(command, payload \\ %{}, opts \\ []) do
    host = opts[:host] || default_host()
    port = opts[:port] || default_port()

    request = %{
      id: Integer.to_string(System.unique_integer([:positive, :monotonic])),
      command: command,
      payload: payload
    }

    with {:ok, socket} <- connect(host, port),
         :ok <- :gen_tcp.send(socket, FW.JSON.encode!(request) <> "\n"),
         {:ok, reply} <- recv_json(socket) do
      :gen_tcp.close(socket)
      {:ok, reply}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp connect(host, port) do
    :gen_tcp.connect(host_tuple(host), port, [:binary, active: false, packet: :line], 5_000)
  end

  defp recv_json(socket) do
    case :gen_tcp.recv(socket, 0, 10_000) do
      {:ok, line} -> FW.JSON.decode(String.trim(line))
      {:error, reason} -> {:error, reason}
    end
  end

  defp host_tuple(host) when is_binary(host) do
    host
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, tuple} -> tuple
      _ -> default_host()
    end
  end

  defp host_tuple(host) when is_tuple(host), do: host

  defp default_host do
    Application.get_env(:fw, :daemon_host, {127, 0, 0, 1})
  end

  defp default_port do
    Application.get_env(:fw, :daemon_port, 47_788)
  end
end
