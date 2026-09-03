defmodule Managoat.Runner.FakeDaemonTest do
  @moduledoc """
  `FakeDaemon.stop/1` is every runner test's `on_exit`, so it must never
  raise: a teardown that exits fails a test that already passed. The socket
  it stops can be gone before it gets there — a test that closed it, the
  daemon going first — which is the race that took a Fountain `main` run
  down (32676969894, partition 3).

  These pin the contract (`:ok` whether the socket is up or already down),
  not the interleaving: a socket dying between an aliveness check and the
  stop cannot be scheduled deterministically, which is why `stop/1` has no
  such check and catches the exit instead.
  """

  use ExUnit.Case, async: true

  alias Managoat.Runner.FakeDaemon
  alias Managoat.Runner.Adapter
  alias Managoat.Runner.Names
  alias Managoat.Sandbox.Command

  @runner_id "0f0e0d0c-0b0a-4908-8706-050403020101"

  test "stop/1 is :ok when the socket is already down" do
    {:ok, %{socket: socket} = daemon} = FakeDaemon.start(@runner_id, name: "dead")

    # Take the socket down before teardown does, the way a test that closes
    # the connection (or a daemon crash) would. Unlink first: the socket is
    # linked to this process and its exit would otherwise take the test with it.
    Process.unlink(socket)
    ref = Process.monitor(socket)
    Process.exit(socket, :kill)
    assert_receive {:DOWN, ^ref, :process, ^socket, _}

    assert :ok = FakeDaemon.stop(daemon)
  end

  test "stop/1 is :ok on a live socket, and the socket goes down" do
    {:ok, %{socket: socket} = daemon} = FakeDaemon.start(@runner_id, name: "live")
    ref = Process.monitor(socket)

    assert :ok = FakeDaemon.stop(daemon)
    assert_receive {:DOWN, ^ref, :process, ^socket, _}
  end

  test "a second daemon for the same runner is refused with a 4409 close" do
    {:ok, daemon} = FakeDaemon.start(@runner_id, name: "first")
    on_exit(fn -> FakeDaemon.stop(daemon) end)

    Process.flag(:trap_exit, true)
    assert {:error, :normal} = FakeDaemon.start(@runner_id, name: "first")
  end

  test "the fake daemon models stderr, default exits and missing sessions" do
    {:ok, daemon} = FakeDaemon.start(@runner_id)
    on_exit(fn -> FakeDaemon.stop(daemon) end)

    name = Names.for_runner(@runner_id)
    assert {:ok, handle} = Adapter.create(name, [])

    assert {:ok, "warning", 0} =
             Adapter.exec(handle, "emit", ["err:warning"], stderr_to_stdout: true)

    assert {:ok, "", 0} = Adapter.exec(handle, "emit", ["err:ignored"], [])

    assert {:ok, command} = Adapter.spawn(handle, "emit", ["err:streamed"], [])
    assert_receive {:stderr, %{ref: command_ref}, "streamed"}
    assert command.ref == command_ref
    assert_receive {:exit, %{ref: ^command_ref}, 0}

    assert {:error, :not_found} = Adapter.attach(handle, "missing-session", [])

    missing = %Command{
      provider: :runner,
      ref: make_ref(),
      private: %{runner_id: @runner_id, name: name, session_id: "missing-session"}
    }

    assert {:error, :command_exited} = Adapter.write_stdin(missing, "hello")
    assert :ok = Adapter.close_stdin(missing)
  end
end
