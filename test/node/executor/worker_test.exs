defmodule AnomaTest.Node.Executor.Worker do
  use ExUnit.Case

  alias Anoma.{Storage, Order}
  alias Anoma.Node.Storage.Communicator
  alias Anoma.Node.Executor.Worker
  import TestHelper.Nock

  setup_all do
    storage = %Anoma.Storage{
      qualified: AnomaTest.Worker.Qualified,
      order: AnomaTest.Worker.Order
    }

    ordering = :worker_storage_com

    unless Process.whereis(ordering) do
      Anoma.Node.Storage.start_link(name: :worker_storage, table: storage)
    end

    snapshot_path = [:my_special_nock_snaphsot | 0]

    env = %Nock{snapshot_path: snapshot_path, ordering: ordering}

    [env: env]
  end

  test "successful worker", %{env: env} do
    key = 555
    id_1 = System.unique_integer([:positive])
    id_2 = System.unique_integer([:positive])

    storage = Communicator.get_storage(env.ordering)
    increment = increment_counter_val(key)

    Storage.ensure_new(storage)
    Communicator.reset(env.ordering)

    spawn_1 = Task.async(Worker, :run, [id_1, increment, env])
    spawn_2 = Task.async(Worker, :run, [id_2, increment, env])

    # simulate sending in 2 different orders
    ord_1 = Communicator.next_order(env.ordering)

    Communicator.new_order(env.ordering, [Order.new(ord_1, id_1, spawn_1.pid)])

    ord_2 = Communicator.next_order(env.ordering)

    Communicator.new_order(env.ordering, [Order.new(ord_2, id_2, spawn_2.pid)])

    # Setup default value for storage
    Storage.put(storage, key, 0)
    # Now set the snapshot up that scry expects
    Storage.put_snapshot(storage, hd(env.snapshot_path))
    # tell the first spawn it can write
    send(spawn_1.pid, {:write_ready, 1})
    assert :ok == Task.await(spawn_1)
    assert {:ok, 1} == Storage.get(storage, key)

    send(spawn_2.pid, {:write_ready, 2})
    assert :ok == Task.await(spawn_2)
    assert {:ok, 2} == Storage.get(storage, key)
  end

  test "failed worker", %{env: env} do
    key = 555
    id = System.unique_integer([:positive])

    storage = Communicator.get_storage(env.ordering)
    increment = increment_counter_val(key)

    Storage.ensure_new(storage)
    Communicator.reset(env.ordering)

    spawn = Task.async(Worker, :run, [id, increment, env])
    Communicator.new_order(env.ordering, [Order.new(1, id, spawn.pid)])

    # do not setup storage, just snapshot with our key
    Storage.put_snapshot(storage, hd(env.snapshot_path))
    # check we are alive even though we failed
    assert Process.alive?(spawn.pid) == true

    send(spawn.pid, {:write_ready, 1})
    assert :error == Task.await(spawn)
    # check that we snapshotted
    assert {:atomic, [{_, _, 2}]} =
             Storage.read_order(storage, hd(env.snapshot_path))
  end

  test "failed worker waits for a snapshot before write", %{env: env} do
    id = System.unique_integer([:positive])

    storage = Communicator.get_storage(env.ordering)
    bogus = [0 | 1]

    Storage.ensure_new(storage)
    Communicator.reset(env.ordering)

    spawn = Task.async(Worker, :run, [id, bogus, env])
    Communicator.new_order(env.ordering, [Order.new(1, id, spawn.pid)])

    # we say that it can write, however we should still be alive, due
    # to the storage snapshot not being ready for it
    send(spawn.pid, {:write_ready, 1})
    assert Process.alive?(spawn.pid)
    # do not setup storage, just snapshot with our key
    Storage.put_snapshot(storage, hd(env.snapshot_path))
    # the storage is there we should be done now
    assert :error == Task.await(spawn)
  end
end