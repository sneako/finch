defmodule Finch.CastPoolOptsTest do
  use ExUnit.Case, async: false

  describe "cast_pool_opts/1" do
    test "treats empty SSLKEYLOGFILE as unset" do
      with_ssl_key_log_file_env("", fn ->
        assert {:ok, %{conn_opts: conn_opts}} = Finch.cast_pool_opts([])
        assert Keyword.fetch!(conn_opts, :ssl_key_log_file_device) == nil
      end)
    end

    test "treats whitespace-only SSLKEYLOGFILE as unset" do
      with_ssl_key_log_file_env("   ", fn ->
        assert {:ok, %{conn_opts: conn_opts}} = Finch.cast_pool_opts([])
        assert Keyword.fetch!(conn_opts, :ssl_key_log_file_device) == nil
      end)
    end

    test "opens SSLKEYLOGFILE when it contains a path" do
      log_file = tmp_path("env-ssl-key-file.log")

      with_ssl_key_log_file_env(log_file, fn ->
        assert {:ok, %{conn_opts: conn_opts}} = Finch.cast_pool_opts([])
        device = Keyword.fetch!(conn_opts, :ssl_key_log_file_device)

        try do
          assert device != nil
        after
          if device, do: File.close(device)
          File.rm(log_file)
        end
      end)
    end

    test "treats empty explicit ssl_key_log_file as unset" do
      log_file = tmp_path("env-ssl-key-file.log")

      with_ssl_key_log_file_env(log_file, fn ->
        try do
          assert {:ok, %{conn_opts: conn_opts}} =
                   Finch.cast_pool_opts(conn_opts: [ssl_key_log_file: ""])

          assert Keyword.fetch!(conn_opts, :ssl_key_log_file_device) == nil
          refute File.exists?(log_file)
        after
          File.rm(log_file)
        end
      end)
    end

    test "opens explicit ssl_key_log_file when it contains a path" do
      env_log_file = tmp_path("env-ssl-key-file.log")
      explicit_log_file = tmp_path("explicit-ssl-key-file.log")

      with_ssl_key_log_file_env(env_log_file, fn ->
        assert {:ok, %{conn_opts: conn_opts}} =
                 Finch.cast_pool_opts(conn_opts: [ssl_key_log_file: explicit_log_file])

        device = Keyword.fetch!(conn_opts, :ssl_key_log_file_device)

        try do
          assert device != nil
          refute File.exists?(env_log_file)
        after
          if device, do: File.close(device)
          File.rm(env_log_file)
          File.rm(explicit_log_file)
        end
      end)
    end
  end

  defp with_ssl_key_log_file_env(value, fun) do
    System.put_env("SSLKEYLOGFILE", value)

    try do
      fun.()
    after
      System.delete_env("SSLKEYLOGFILE")
    end
  end

  defp tmp_path(filename) do
    Path.join(System.tmp_dir(), "finch-#{System.unique_integer([:positive])}-#{filename}")
  end
end
