defmodule EventStore.Subscriptions.AllStreamsSubscriptionTest do
  use EventStore.StorageCase

  alias EventStore.EventFactory
  alias EventStore.Storage.{Appender,Stream}
  alias EventStore.Subscriptions.StreamSubscription

  @all_stream "$all"
  @subscription_name "test_subscription"

  setup do
    storage_config = Application.get_env(:eventstore, EventStore.Storage)

    {:ok, conn} = Postgrex.start_link(storage_config)
    {:ok, %{conn: conn}}
  end

  test "create subscription to all streams" do
    subscription = create_subscription()

    assert subscription.state == :catching_up
    assert subscription.data.subscription_name == @subscription_name
    assert subscription.data.subscriber == self()
    assert subscription.data.last_seen == 0
    assert subscription.data.last_ack == 0
  end

  test "create subscription to all streams from starting event id" do
    subscription = create_subscription(start_from_event_id: 2)

    assert subscription.state == :catching_up
    assert subscription.data.subscription_name == @subscription_name
    assert subscription.data.subscriber == self()
    assert subscription.data.last_seen == 2
    assert subscription.data.last_ack == 2
  end

  test "catch-up subscription, no persisted events" do
    subscription =
      create_subscription()
      |> StreamSubscription.catch_up

    assert subscription.state == :subscribed
    assert subscription.data.last_seen == 0
  end

  test "catch-up subscription, unseen persisted events", %{conn: conn} do
    stream_uuid = UUID.uuid4
    {:ok, stream_id} = Stream.create_stream(conn, stream_uuid)
    recorded_events = EventFactory.create_recorded_events(3, stream_id)
    {:ok, 3} = Appender.append(conn, stream_id, recorded_events)

    subscription =
      create_subscription()
      |> StreamSubscription.catch_up

    assert subscription.state == :subscribed
    assert subscription.data.last_seen == 3

    assert_receive {:events, received_events, nil}
    expected_events = EventFactory.deserialize_events(recorded_events)

    assert pluck(received_events, :correlation_id) == pluck(expected_events, :correlation_id)
    assert pluck(received_events, :data) == pluck(expected_events, :data)
  end

  test "notify events" do
    events = EventFactory.create_recorded_events(1, 1)

    subscription =
      create_subscription()
      |> StreamSubscription.catch_up
      |> StreamSubscription.notify_events(events)

    assert subscription.state == :subscribed

    assert_receive {:events, received_events, nil}

    assert pluck(received_events, :correlation_id) == pluck(events, :correlation_id)
    assert pluck(received_events, :data) == pluck(events, :data)
  end

  describe "ack notified events" do
    test "should skip events during catch up when acknowledged", %{conn: conn} do
      stream_uuid = UUID.uuid4
      {:ok, stream_id} = Stream.create_stream(conn, stream_uuid)
      {:ok, 3} = Appender.append(conn, stream_id, EventFactory.create_recorded_events(3, stream_id))

      subscription =
        create_subscription()
        |> StreamSubscription.catch_up

      assert subscription.state == :subscribed
      assert subscription.data.last_seen == 3
      assert subscription.data.last_ack == 0

      assert_receive {:events, received_events, nil}
      assert length(received_events) == 3

      subscription =
        subscription
        |> StreamSubscription.ack(3)

      assert subscription.state == :subscribed
      assert subscription.data.last_seen == 3
      assert subscription.data.last_ack == 3

      subscription =
        create_subscription()
        |> StreamSubscription.catch_up

      # should not receive already seen events
      refute_receive {:events, _received_events, nil}

      assert subscription.state == :subscribed
      assert subscription.data.last_seen == 3
      assert subscription.data.last_ack == 3
    end

    test "should replay events when catching up and events had not been acknowledged", %{conn: conn} do
      stream_uuid = UUID.uuid4
      {:ok, stream_id} = Stream.create_stream(conn, stream_uuid)
      {:ok, 3} = Appender.append(conn, stream_id, EventFactory.create_recorded_events(3, stream_id))

      subscription =
        create_subscription()
        |> StreamSubscription.catch_up

      assert subscription.state == :subscribed

      assert_receive {:events, received_events, nil}
      assert length(received_events) == 3
      assert subscription.data.last_seen == 3
      assert subscription.data.last_ack == 0

      subscription =
        create_subscription()
        |> StreamSubscription.catch_up

      # should receive already seen events
      assert_receive {:events, received_events, nil}
      assert length(received_events) == 3

      assert subscription.state == :subscribed
      assert subscription.data.last_seen == 3
      assert subscription.data.last_ack == 0
    end

    test "should not notify events until ack received" do
      events = EventFactory.create_recorded_events(6, 1)
      initial_events = Enum.take(events, 3)
      remaining_events = Enum.drop(events, 3)

      subscription =
        create_subscription()
        |> StreamSubscription.catch_up
        |> StreamSubscription.notify_events(initial_events)
        |> StreamSubscription.notify_events(remaining_events)

      assert subscription.state == :subscribed

      # only receive initial events
      assert_receive {:events, received_events, nil}
      refute_receive {:events, _received_events, nil}

      assert length(received_events) == 3
      assert pluck(received_events, :correlation_id) == pluck(initial_events, :correlation_id)
      assert pluck(received_events, :data) == pluck(initial_events, :data)

      # don't receive remaining events until ack received for all initial events
      subscription = ack_refute_receive(subscription, 1)
      subscription = ack_refute_receive(subscription, 2)

      subscription =
        subscription
        |> StreamSubscription.ack(3)

      assert subscription.state == :subscribed

      # now receive all remaining events
      assert_receive {:events, received_events, nil}

      assert length(received_events) == 3
      assert pluck(received_events, :correlation_id) == pluck(remaining_events, :correlation_id)
      assert pluck(received_events, :data) == pluck(remaining_events, :data)
    end
  end

  describe "pending event buffer limit" do
    test "should restrict pending events until ack" do
      events = EventFactory.create_recorded_events(6, 1)
      initial_events = Enum.take(events, 3)
      remaining_events = Enum.drop(events, 3)

      subscription =
        create_subscription(max_size: 3)
        |> StreamSubscription.catch_up
        |> StreamSubscription.notify_events(initial_events)
        |> StreamSubscription.notify_events(remaining_events)

      assert subscription.state == :max_capacity

      assert_receive {:events, received_events, nil}
      refute_receive {:events, _received_events, nil}

      assert length(received_events) == 3
      assert pluck(received_events, :correlation_id) == pluck(initial_events, :correlation_id)
      assert pluck(received_events, :data) == pluck(initial_events, :data)

      subscription =
        subscription
        |> StreamSubscription.ack(3)

      assert subscription.state == :catching_up

      # now receive all remaining events
      assert_receive {:events, received_events, nil}

      assert length(received_events) == 3
      assert pluck(received_events, :correlation_id) == pluck(remaining_events, :correlation_id)
      assert pluck(received_events, :data) == pluck(remaining_events, :data)
    end

    test "should receive pending events on ack after reaching max capacity" do
      events = EventFactory.create_recorded_events(6, 1)
      initial_events = Enum.take(events, 3)
      remaining_events = Enum.drop(events, 3)

      subscription =
        create_subscription(max_size: 3)
        |> StreamSubscription.catch_up
        |> StreamSubscription.notify_events(initial_events)
        |> StreamSubscription.notify_events(remaining_events)

      assert subscription.state == :max_capacity

      subscription =
        subscription
        |> StreamSubscription.ack(1)

      assert subscription.state == :max_capacity

      assert_receive {:events, received_events, nil}
      refute_receive {:events, _received_events, nil}

      assert length(received_events) == 3

      subscription =
        subscription
        |> StreamSubscription.ack(2)

      assert subscription.state == :max_capacity

      subscription =
        subscription
        |> StreamSubscription.ack(3)

      assert subscription.state == :catching_up

      # now receive all remaining events
      assert_receive {:events, received_events, nil}

      assert length(received_events) == 3
      assert pluck(received_events, :correlation_id) == pluck(remaining_events, :correlation_id)
      assert pluck(received_events, :data) == pluck(remaining_events, :data)
    end
  end

  defp create_subscription(opts \\ []) do
    StreamSubscription.new
    |> StreamSubscription.subscribe(@all_stream, nil, @subscription_name, nil, self(), opts)
  end

  defp ack_refute_receive(subscription, ack) do
    subscription =
      subscription
      |> StreamSubscription.ack(ack)

    assert subscription.state == :subscribed
    assert subscription.data.last_seen == 6
    assert subscription.data.last_ack == ack

    # don't receive remaining events until ack received for all initial events
    refute_receive {:events, _received_events, nil}

    subscription
  end

  defp pluck(enumerable, field) do
    Enum.map(enumerable, &Map.get(&1, field))
  end
end
