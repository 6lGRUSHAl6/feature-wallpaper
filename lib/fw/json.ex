defmodule FW.JSON do
  @moduledoc """
  Minimal JSON codec for fw.
  """

  def encode!(value) do
    encode(value)
  end

  def encode(value) do
    value
    |> encode_value()
    |> IO.iodata_to_binary()
  end

  def decode(text) when is_binary(text) do
    case parse_value(skip_ws(text)) do
      {:ok, value, rest} ->
        case skip_ws(rest) do
          <<>> -> {:ok, value}
          _ -> {:error, :trailing_data}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp encode_value(nil), do: "null"
  defp encode_value(true), do: "true"
  defp encode_value(false), do: "false"
  defp encode_value(value) when is_integer(value), do: Integer.to_string(value)
  defp encode_value(value) when is_float(value), do: :erlang.float_to_binary(value, [:compact])
  defp encode_value(value) when is_binary(value), do: ["\"", escape_string(value), "\""]
  defp encode_value(value) when is_atom(value), do: encode_value(Atom.to_string(value))
  defp encode_value(value) when is_list(value), do: encode_list(value)
  defp encode_value(value) when is_map(value), do: encode_map(value)
  defp encode_value(value), do: encode_value(to_string(value))

  defp encode_list([]), do: "[]"
  defp encode_list(list), do: ["[", Enum.intersperse(Enum.map(list, &encode_value/1), ","), "]"]

  defp encode_map(map) do
    entries =
      map
      |> Enum.map(fn {key, value} -> [encode_value(to_string(key)), ":", encode_value(value)] end)

    ["{", Enum.intersperse(entries, ","), "}"]
  end

  defp escape_string(<<>>), do: <<>>
  defp escape_string(<<?", rest::binary>>), do: ["\\\"", escape_string(rest)]
  defp escape_string(<<?\\, rest::binary>>), do: ["\\\\", escape_string(rest)]
  defp escape_string(<<?\b, rest::binary>>), do: ["\\b", escape_string(rest)]
  defp escape_string(<<?\f, rest::binary>>), do: ["\\f", escape_string(rest)]
  defp escape_string(<<?\n, rest::binary>>), do: ["\\n", escape_string(rest)]
  defp escape_string(<<?\r, rest::binary>>), do: ["\\r", escape_string(rest)]
  defp escape_string(<<?\t, rest::binary>>), do: ["\\t", escape_string(rest)]

  defp escape_string(<<char::utf8, rest::binary>>) when char < 0x20 do
    ["\\u", hex4(char), escape_string(rest)]
  end

  defp escape_string(<<char::utf8, rest::binary>>), do: [<<char::utf8>>, escape_string(rest)]

  defp hex4(codepoint) do
    codepoint
    |> Integer.to_string(16)
    |> String.upcase()
    |> String.pad_leading(4, "0")
  end

  defp skip_ws(<<char, rest::binary>>) when char in [32, 9, 10, 13], do: skip_ws(rest)
  defp skip_ws(rest), do: rest

  defp parse_value(<<"null", rest::binary>>), do: {:ok, nil, rest}
  defp parse_value(<<"true", rest::binary>>), do: {:ok, true, rest}
  defp parse_value(<<"false", rest::binary>>), do: {:ok, false, rest}
  defp parse_value(<<"{", rest::binary>>), do: parse_object(skip_ws(rest), %{})
  defp parse_value(<<"[", rest::binary>>), do: parse_array(skip_ws(rest), [])
  defp parse_value(<<34, rest::binary>>), do: parse_string(rest, <<>>)
  defp parse_value(binary), do: parse_number(binary)

  defp parse_object(<<"}", rest::binary>>, acc), do: {:ok, acc, rest}

  defp parse_object(binary, acc) do
    with {:ok, key, rest1} <- parse_value(binary),
         ":" <> rest2 <- skip_ws(rest1),
         {:ok, value, rest3} <- parse_value(skip_ws(rest2)) do
      case skip_ws(rest3) do
        <<",", rest4::binary>> -> parse_object(skip_ws(rest4), Map.put(acc, key, value))
        <<"}", rest4::binary>> -> {:ok, Map.put(acc, key, value), rest4}
        _ -> {:error, :invalid_object}
      end
    else
      _ -> {:error, :invalid_object}
    end
  end

  defp parse_array(<<"]", rest::binary>>, acc), do: {:ok, Enum.reverse(acc), rest}

  defp parse_array(binary, acc) do
    with {:ok, value, rest1} <- parse_value(binary) do
      case skip_ws(rest1) do
        <<",", rest2::binary>> -> parse_array(skip_ws(rest2), [value | acc])
        <<"]", rest2::binary>> -> {:ok, Enum.reverse([value | acc]), rest2}
        _ -> {:error, :invalid_array}
      end
    else
      _ -> {:error, :invalid_array}
    end
  end

  defp parse_string(<<34, rest::binary>>, acc), do: {:ok, acc, rest}

  defp parse_string(<<"\\", rest::binary>>, acc) do
    case rest do
      <<34, tail::binary>> ->
        parse_string(tail, <<acc::binary, 34>>)

      <<"\\", tail::binary>> ->
        parse_string(tail, <<acc::binary, 92>>)

      <<"/", tail::binary>> ->
        parse_string(tail, <<acc::binary, 47>>)

      <<"b", tail::binary>> ->
        parse_string(tail, <<acc::binary, 8>>)

      <<"f", tail::binary>> ->
        parse_string(tail, <<acc::binary, 12>>)

      <<"n", tail::binary>> ->
        parse_string(tail, <<acc::binary, 10>>)

      <<"r", tail::binary>> ->
        parse_string(tail, <<acc::binary, 13>>)

      <<"t", tail::binary>> ->
        parse_string(tail, <<acc::binary, 9>>)

      <<"u", hex::binary-size(4), tail::binary>> ->
        case Integer.parse(hex, 16) do
          {codepoint, ""} -> parse_string(tail, <<acc::binary, codepoint::utf8>>)
          _ -> {:error, :invalid_unicode_escape}
        end

      _ ->
        {:error, :invalid_escape}
    end
  end

  defp parse_string(<<char::utf8, rest::binary>>, acc),
    do: parse_string(rest, <<acc::binary, char::utf8>>)

  defp parse_string(<<>>, _acc), do: {:error, :unterminated_string}

  defp parse_number(binary) do
    regex = ~r/^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/

    case Regex.run(regex, binary, capture: :first) do
      [number | _] ->
        rest = binary_part(binary, byte_size(number), byte_size(binary) - byte_size(number))

        case Integer.parse(number) do
          {int, ""} ->
            {:ok, int, rest}

          _other ->
            case Float.parse(number) do
              {float, ""} -> {:ok, float, rest}
              _ -> {:error, :invalid_number}
            end
        end

      _ ->
        {:error, :invalid_number}
    end
  end
end
