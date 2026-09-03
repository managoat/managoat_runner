defmodule Managoat.Runner.ConnectionTest do
  @moduledoc """
  The connection's side of the host contract: which callback fires when, in
  what order, and with what. A recording host wraps the reference one so the
  daemon still works end to end (`call/3` routes through the configured
  `Managoat.Runner.Host.Local`) while every callback lands in the test's
  mailbox — the init map's `host:` is what lets the two run side by side.
  """
  # These tests deliberately register live and non-responsive processes in
  # the application-wide reference host. Keep them out of the async pool so
  # `Adapter.list_all_names/0` tests never observe a transient fake runner.
  use ExUnit.Case, async: false

  alias Managoat.Runner.Adapter
  alias Managoat.Runner.Connection
  alias Managoat.Runner.FakeDaemon
  alias Managoat.Runner.Host.Local
  alias Managoat.Runner.Names

  defmodule Recording do
    @moduledoc false
    @behaviour Managoat.Runner.Host

    # The test process, found through the meta the connection hands back —
    # which is also what pins that `meta` reaches every callback untouched.
    defp notify(meta, event), do: send(meta.test, event)

    @impl true
    def register(id, meta) do
      notify(meta, {:register, id, meta})
      Local.register(id, meta)
    end

    @impl true
    def unregister(id) do
      case Registry.lookup(Local.registry(), id) do
        [{_, meta}] -> notify(meta, {:unregister, id})
        [] -> :ok
      end

      Local.unregister(id)
    end

    @impl true
    def whereis(id), do: Local.whereis(id)

    @impl true
    def online, do: Local.online()

    @impl true
    def heartbeat(id) do
      case Registry.lookup(Local.registry(), id) do
        [{_, meta}] -> notify(meta, {:heartbeat, id})
        [] -> :ok
      end

      :ok
    end

    @impl true
    def presence(id, status, meta) do
      notify(meta, {:presence, id, status, meta})
      :ok
    end
  end

  @runner_id "0f0e0d0c-0b0a-4908-8706-050403020103"

  test "connect registers then announces online; disconnect unregisters then announces offline" do
    meta = %{test: self(), tenant: "t-1"}
    {:ok, %{socket: socket} = daemon} = FakeDaemon.start(@runner_id, meta: meta, host: Recording)

    assert_receive {:register, @runner_id, ^meta}
    assert_receive {:presence, @runner_id, :online, ^meta}
    assert Local.whereis(@runner_id) == socket
    assert {@runner_id, meta} in Local.online()

    # The daemon works through the configured host while the recording host
    # observes: a request round-trips.
    name = Names.for_runner(@runner_id)
    assert {:ok, _handle} = Adapter.create(name, [])

    FakeDaemon.stop(daemon)
    assert_receive {:unregister, @runner_id}
    assert_receive {:presence, @runner_id, :offline, ^meta}
    assert Local.whereis(@runner_id) == nil
  end

  test "the heartbeat reaches the host and pings the daemon" do
    meta = %{test: self()}
    {:ok, %{socket: socket} = daemon} = FakeDaemon.start(@runner_id, meta: meta, host: Recording)
    on_exit(fn -> FakeDaemon.stop(daemon) end)

    send(socket, :heartbeat)
    assert_receive {:heartbeat, @runner_id}
  end

  test "a refused registration never announces presence and closes with 4409" do
    meta = %{test: self()}
    {:ok, daemon} = FakeDaemon.start(@runner_id, meta: meta, host: Recording)
    on_exit(fn -> FakeDaemon.stop(daemon) end)
    assert_receive {:presence, @runner_id, :online, _}

    assert {:stop, :normal, {4409, reason}, state} =
             Connection.init(%{runner_id: @runner_id, name: "dup", meta: meta, host: Recording})

    assert reason =~ "dup"
    refute state.registered
    assert_receive {:register, @runner_id, ^meta}
    refute_receive {:presence, @runner_id, _, _}, 50

    # terminate/2 on the refused state neither unregisters the real one nor
    # announces anything.
    assert :ok = Connection.terminate(:normal, state)
    refute_receive {:unregister, @runner_id}, 50
    refute_receive {:presence, @runner_id, :offline, _}, 50
  end

  test "the host may send :runner_deleted to close the socket with 4404" do
    {:ok, %{socket: socket} = daemon} = FakeDaemon.start(@runner_id, name: "gone")
    on_exit(fn -> FakeDaemon.stop(daemon) end)

    Process.unlink(socket)
    ref = Process.monitor(socket)
    send(Local.whereis(@runner_id), {:runner_deleted, @runner_id})
    assert_receive {:DOWN, ^ref, :process, ^socket, _}, 1_000
    assert Local.whereis(@runner_id) == nil
  end

  test "call/3 on a runner nobody registered is :runner_offline" do
    assert {:error, {:unavailable, :runner_offline}} =
             Connection.call("00000000-0000-4000-8000-000000000000", %{op: "list"})

    assert :ok = Connection.unsubscribe("00000000-0000-4000-8000-000000000000", "s-1", make_ref())
  end

  test "a disconnect fails every pending caller with :runner_disconnected" do
    {:ok, %{socket: socket} = daemon} = FakeDaemon.start(@runner_id, name: "drop")
    Process.unlink(socket)

    # Bypass the daemon: a request the daemon never answers stays pending
    # until the socket closes.
    ref = make_ref()
    send(socket, {:rpc, self(), ref, %{op: "never", name: "x", id: "ignored"}, nil})
    FakeDaemon.stop(daemon)

    assert_receive {:runner_reply, ^ref, {:error, {:unavailable, :runner_disconnected}}}
  end

  test "call/3 distinguishes a process that dies from one that stops replying" do
    dead_id = "dead-#{System.unique_integer([:positive])}"
    timeout_id = "timeout-#{System.unique_integer([:positive])}"
    parent = self()

    spawn(fn ->
      :ok = Local.register(dead_id, %{})
      send(parent, {:registered, dead_id})
      receive do: ({:rpc, _from, _ref, _payload, _subscribe} -> exit(:daemon_crashed))
    end)

    assert_receive {:registered, ^dead_id}

    assert {:error, {:unavailable, :runner_disconnected}} =
             Connection.call(dead_id, %{op: "list"}, timeout: 100)

    waiter =
      spawn(fn ->
        :ok = Local.register(timeout_id, %{})
        send(parent, {:registered, timeout_id})

        receive do
          {:rpc, _from, _ref, _payload, _subscribe} ->
            receive do: (:stop -> :ok)
        end
      end)

    assert_receive {:registered, ^timeout_id}

    assert {:error, {:unavailable, :runner_timeout}} =
             Connection.call(timeout_id, %{op: "list"}, timeout: 10)

    send(waiter, :stop)
  end

  test "wire replies reject malformed shapes and stream data degrades safely" do
    ref = make_ref()

    state = %{
      runner_id: @runner_id,
      pending: %{7 => {self(), ref, nil}},
      subs: %{"s-1" => [{self(), ref, 7}]},
      owners: %{}
    }

    malformed = Jason.encode!(%{"id" => 7, "ok" => "not-a-boolean"})
    assert {:ok, state} = Connection.handle_in({malformed, [opcode: :text]}, state)
    assert state.pending == %{}

    assert_receive {:runner_reply, ^ref,
                    {:error, {:provider, :runner, {:malformed_reply, %{"id" => 7}}}}}

    # A late or duplicate reply is ignored rather than delivered to another caller.
    assert {:ok, ^state} =
             Connection.handle_in(
               {Jason.encode!(%{"id" => 99, "ok" => true}), [opcode: :text]},
               state
             )

    stderr =
      Jason.encode!(%{"stream" => "stderr", "session_id" => "s-1", "data" => "not base64"})

    assert {:ok, ^state} = Connection.handle_in({stderr, [opcode: :text]}, state)
    assert_receive {:stderr, %{ref: ^ref}, "not base64"}

    missing_data = Jason.encode!(%{"stream" => "stdout", "session_id" => "s-1"})
    assert {:ok, ^state} = Connection.handle_in({missing_data, [opcode: :text]}, state)
    assert_receive {:stdout, %{ref: ^ref}, ""}

    unknown = Jason.encode!(%{"stream" => "progress", "session_id" => "s-1"})
    assert {:ok, ^state} = Connection.handle_in({unknown, [opcode: :text]}, state)
    refute_receive _
    assert {:ok, ^state} = Connection.handle_info(:unexpected, state)
  end

  test "unsubscribe detaches only after the final local subscriber leaves" do
    first = make_ref()
    second = make_ref()

    state = %{
      runner_id: @runner_id,
      subs: %{"s-1" => [{self(), first, 1}, {self(), second, 2}]},
      owners: %{}
    }

    assert {:ok, state} = Connection.handle_info({:unsubscribe, "s-1", first}, state)
    assert state.subs == %{"s-1" => [{self(), second, 2}]}

    assert {:push, {:text, detach}, state} =
             Connection.handle_info({:unsubscribe, "s-1", second}, state)

    assert state.subs == %{}
    assert %{"id" => 0, "op" => "detach", "session_id" => "s-1"} = Jason.decode!(detach)

    # Repeating an unsubscribe is total and still leaves the daemon detached.
    assert {:push, {:text, _}, ^state} =
             Connection.handle_info({:unsubscribe, "s-1", make_ref()}, state)
  end

  test "an owner exit drops its sessions without disturbing other owners" do
    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    owner_ref = make_ref()
    survivor_ref = make_ref()

    state = %{
      runner_id: @runner_id,
      subs: %{
        "gone" => [{owner, owner_ref, 1}],
        "shared" => [{owner, owner_ref, 2}, {self(), survivor_ref, 3}]
      },
      owners: %{owner => make_ref()}
    }

    assert {:push, [{:text, detach}], state} =
             Connection.handle_info({:DOWN, make_ref(), :process, owner, :normal}, state)

    assert %{"op" => "detach", "session_id" => "gone"} = Jason.decode!(detach)
    assert state.subs == %{"shared" => [{self(), survivor_ref, 3}]}
    refute Map.has_key?(state.owners, owner)

    assert {:ok, ^state} =
             Connection.handle_info({:DOWN, make_ref(), :process, owner, :normal}, state)

    send(owner, :stop)
  end

  test "non-JSON and binary frames close the socket with 1003" do
    state = %{runner_id: @runner_id, pending: %{}, subs: %{}, owners: %{}}

    assert {:stop, :normal, {1003, _}, ^state} =
             Connection.handle_in({"nope", [opcode: :text]}, state)

    assert {:stop, :normal, {1003, _}, ^state} =
             Connection.handle_in({<<0>>, [opcode: :binary]}, state)

    assert {:ok, ^state} = Connection.handle_in({~s({"hello": 1}), [opcode: :text]}, state)
    assert {:ok, ^state} = Connection.handle_control({:ping, ""}, state)
  end

  test "normalize_error/2 maps the daemon's codes onto the sandbox taxonomy" do
    assert Connection.normalize_error("not_found", nil) == :not_found
    assert Connection.normalize_error("command_exited", nil) == :command_exited
    assert Connection.normalize_error("not_supported", "x") == :not_supported
    assert Connection.normalize_error("invalid", "why") == {:invalid, "why"}
    assert Connection.normalize_error("unavailable", "why") == {:unavailable, "why"}
    assert Connection.normalize_error("write_failed", "why") == {:write_failed, "why"}
    assert Connection.normalize_error("weird", "d") == {:provider, :runner, {"weird", "d"}}
  end
end
