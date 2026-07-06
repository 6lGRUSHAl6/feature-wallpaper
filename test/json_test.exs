defmodule FW.JSONTest do
  use ExUnit.Case, async: true

  describe "encode/1" do
    test "encodes scalars" do
      assert FW.JSON.encode!(nil) == "null"
      assert FW.JSON.encode!(true) == "true"
      assert FW.JSON.encode!(false) == "false"
      assert FW.JSON.encode!(42) == "42"
      assert FW.JSON.encode!("hello") == ~s("hello")
    end

    test "encodes atoms as strings" do
      assert FW.JSON.encode!(:ok) == ~s("ok")
    end

    test "encodes maps with string keys" do
      assert FW.JSON.encode!(%{"a" => 1}) == ~s({"a":1})
    end

    test "encodes maps with atom keys the same as string keys" do
      assert FW.JSON.encode!(%{a: 1}) == ~s({"a":1})
    end

    test "encodes nested maps and lists" do
      encoded = FW.JSON.encode!(%{"outer" => %{"inner" => [1, 2, 3]}})
      assert encoded == ~s({"outer":{"inner":[1,2,3]}})
    end

    test "escapes quotes, backslashes and control characters (round-trip safe)" do
      # Deliberately avoids asserting on the raw escaped bytes (easy to get
      # wrong by hand) and instead proves encode/decode are inverses for a
      # string containing every character class that needs escaping.
      tricky = ~S(back\slash "quote" and) <> "\ttab\nnewline"
      encoded = FW.JSON.encode!(%{"path" => tricky})

      assert {:ok, %{"path" => ^tricky}} = FW.JSON.decode(encoded)
      refute encoded =~ "\n", "raw newline must not appear unescaped in encoded JSON"
      refute encoded =~ "\t", "raw tab must not appear unescaped in encoded JSON"
    end

    test "a wallpaper path containing a double quote survives a full encode/decode round-trip" do
      # This is the realistic case that matters for fw: a user's file path
      # (or an error message echoed back from fw_renderer) can legitimately
      # contain a double quote, which would otherwise break the JSON frame
      # sent over the Port/socket protocol.
      path = ~S(/tmp/my "special" wallpaper.png)
      request = %{"id" => "1", "command" => "apply", "payload" => %{"path" => path}}

      assert {:ok, decoded} = request |> FW.JSON.encode!() |> FW.JSON.decode()
      assert decoded["payload"]["path"] == path
    end
  end

  describe "decode/1" do
    test "round-trips a flat object" do
      original = %{"id" => "1", "command" => "apply", "path" => "/tmp/a.png"}
      assert {:ok, decoded} = original |> FW.JSON.encode!() |> FW.JSON.decode()
      assert decoded == original
    end

    test "round-trips a nested payload object, matching the fw_renderer protocol shape" do
      original = %{
        "id" => "7",
        "command" => "apply",
        "payload" => %{"path" => "/tmp/a.png", "scaling" => "fill"}
      }

      assert {:ok, decoded} = original |> FW.JSON.encode!() |> FW.JSON.decode()
      assert decoded == original
    end

    test "decodes numbers, including floats and negatives" do
      assert {:ok, 42} = FW.JSON.decode("42")
      assert {:ok, -7} = FW.JSON.decode("-7")
      assert {:ok, 3.5} = FW.JSON.decode("3.5")
    end

    test "decodes escape sequences" do
      assert {:ok, "line1\nline2\ttab\"quote\""} =
               FW.JSON.decode(~s("line1\\nline2\\ttab\\"quote\\""))
    end

    test "decodes unicode escapes" do
      assert {:ok, "caf\u00e9"} = FW.JSON.decode(~s("caf\\u00e9"))
    end

    test "decodes an empty object and empty array" do
      assert {:ok, %{}} = FW.JSON.decode("{}")
      assert {:ok, []} = FW.JSON.decode("[]")
    end

    test "returns an error for malformed JSON instead of raising" do
      assert {:error, _reason} = FW.JSON.decode("{not valid json")
      assert {:error, _reason} = FW.JSON.decode("")
      assert {:error, _reason} = FW.JSON.decode(~s[{"a":1)])
    end

    test "returns an error for trailing data after a valid value" do
      assert {:error, :trailing_data} = FW.JSON.decode(~s({"a":1} garbage))
    end

    test "ignores surrounding whitespace" do
      assert {:ok, %{"a" => 1}} = FW.JSON.decode("  \n {\"a\": 1} \t ")
    end
  end
end
