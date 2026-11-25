defmodule HighWireWeb.PrivatePublishTest do
  @moduledoc """
  The publish decisions that keep a private thread private.

  The engine is off under test, so a publish returns `{:error, :offline}`
  and leaves nothing to look at. These tests stand a stub under the
  `HighWire.Timeline` name to capture the content that reaches the
  publish chokepoint, then open it with a recipient's own key: a reply
  or a like on a private thread, and a private post from the composer,
  must arrive sealed and addressed to the thread's participants.

  The tests are synchronous because the stub holds a global name.
  """

  use HighWireWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias HighWire.SSB.PrivateBox

  defmodule TimelineStub do
    @moduledoc false
    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner, name: HighWire.Timeline)

    @impl true
    def init(owner), do: {:ok, owner}

    @impl true
    def handle_call({:publish_content, content}, _from, owner) do
      send(owner, {:published, content})
      {:reply, {:ok, "%stub=.sha256"}, owner}
    end

    def handle_call(:snapshot, _from, owner) do
      payload = %{profiles: %{}, like_counts: %{}, likes_by: %{}, my_likes: [], blob_rev: 0}
      {:reply, {:ok, payload}, owner}
    end

    def handle_call({:post, _key}, _from, owner), do: {:reply, nil, owner}
    def handle_call(_call, _from, owner), do: {:reply, :ok, owner}

    @impl true
    def handle_cast(_msg, owner), do: {:noreply, owner}
  end

  defp keypair, do: :enacl.crypto_sign_ed25519_keypair()
  defp feed_id(%{public: pk}), do: "@" <> Base.encode64(pk) <> ".ed25519"

  # The real Timeline runs in test with its engine disabled, so it would
  # answer a publish with `{:error, :offline}` and never expose what was
  # handed to the chokepoint. Hand the name to the stub for the publish
  # itself, then put the supervised child back.
  defp with_publish_capture(fun) do
    :ok = Supervisor.terminate_child(HighWire.Supervisor, HighWire.Timeline)

    on_exit(fn ->
      {:ok, _pid} = Supervisor.restart_child(HighWire.Supervisor, HighWire.Timeline)
    end)

    start_supervised!({TimelineStub, self()})
    fun.()
  end

  # Both views mount before the stub exists (the engine is off, so they
  # arrive disabled); this stands up the state a live thread would have.
  defp seed(view, assigns) do
    :sys.replace_state(view.pid, fn state ->
      socket = state.socket
      old = socket.assigns

      changed =
        Enum.reduce(Map.keys(assigns), old.__changed__, fn key, acc ->
          Map.put(acc, key, Map.get(old, key))
        end)

      socket = %{socket | assigns: old |> Map.merge(assigns) |> Map.put(:__changed__, changed)}
      %{state | socket: socket}
    end)

    send(view.pid, :nudge)
    :sys.get_state(view.pid)
    view
  end

  defp private_root(key) do
    %{
      "key" => key,
      "value" => %{
        "author" => "@vkdMlsuBgzzo5eLS3LZLdqnBpZ26OauJOMIq9gQ2E7E=.ed25519",
        "timestamp" => 1_700_000_000_000,
        "private" => true,
        "content" => %{"type" => "post", "text" => "the secret"}
      }
    }
  end

  describe "a thread opened in the post viewer" do
    test "a reply is boxed for the root author, the author reading it, and the repliers", %{
      conn: conn
    } do
      kp = keypair()
      self_id = feed_id(kp)
      key = "%private-root=.sha256"
      root = private_root(key)

      replier = %{
        "key" => "%private-reply=.sha256",
        "value" => %{
          "author" => "@0W1ekqmNIN4e1IsAWBM1Kft6w5w86BMUdPO2M0SO83I=.ed25519",
          "timestamp" => 1_700_000_060_000,
          "content" => %{"type" => "post", "text" => "first answer"}
        }
      }

      {:ok, view, _html} = live(conn, "/post/" <> Base.url_encode64(key, padding: false))

      view
      |> seed(%{
        status: :ok,
        self_id: self_id,
        not_found: false,
        root: root,
        replies: [replier]
      })

      with_publish_capture(fn ->
        render_change(view, "reply-draft", %{"body" => "the answer"})
        render_submit(view, "reply", %{})

        assert_receive {:published, content}
        assert PrivateBox.private?(content)
        refute content =~ "the answer"

        assert {:ok, json} = PrivateBox.decrypt(content, kp.secret)

        assert %{"type" => "post", "text" => "the answer", "recps" => recps} =
                 Jason.decode!(json)

        assert recps == [root["value"]["author"], self_id, replier["value"]["author"]]
      end)
    end

    test "a reply on a thread too large for one box is refused, and says why", %{conn: conn} do
      kp = keypair()
      self_id = feed_id(kp)
      key = "%private-root=.sha256"
      root = private_root(key)

      # Seven repliers plus the root author and self: nine people, and a
      # box carries seven, so somebody would have to be left out.
      replies =
        for i <- 1..7 do
          %{
            "key" => "%private-reply-#{i}=.sha256",
            "value" => %{
              "author" => feed_id(keypair()),
              "timestamp" => 1_700_000_000_000 + i,
              "content" => %{"type" => "post", "text" => "answer #{i}"}
            }
          }
        end

      {:ok, view, _html} = live(conn, "/post/" <> Base.url_encode64(key, padding: false))

      view
      |> seed(%{
        status: :ok,
        self_id: self_id,
        not_found: false,
        root: root,
        replies: replies
      })

      with_publish_capture(fn ->
        render_change(view, "reply-draft", %{"body" => "the answer"})
        render_submit(view, "reply", %{})

        refute_receive {:published, _}

        html = render(view)

        assert html =~
                 "A private message reaches 7 people; this thread has 9. Nothing was sent."

        # The draft is still there, so nothing typed is lost to the refusal.
        assert html =~ "the answer"
      end)
    end

    test "a like on a thread too large for one box is refused, and says why", %{conn: conn} do
      kp = keypair()
      self_id = feed_id(kp)
      key = "%private-root=.sha256"
      root = private_root(key)

      replies =
        for i <- 1..7 do
          %{
            "key" => "%private-reply-#{i}=.sha256",
            "value" => %{
              "author" => feed_id(keypair()),
              "timestamp" => 1_700_000_000_000 + i,
              "content" => %{"type" => "post", "text" => "answer #{i}"}
            }
          }
        end

      {:ok, view, _html} = live(conn, "/post/" <> Base.url_encode64(key, padding: false))

      view
      |> seed(%{
        status: :ok,
        self_id: self_id,
        not_found: false,
        root: root,
        replies: replies
      })

      with_publish_capture(fn ->
        view
        |> element(~s(button[phx-value-key="#{key}"][aria-label="Like"]))
        |> render_click()

        refute_receive {:published, _}

        assert render(view) =~
                 "That like didn&#39;t go through: a private message reaches 7 people, and this thread has 9 on it."
      end)
    end

    test "a like is boxed as a vote on the thread", %{conn: conn} do
      kp = keypair()
      self_id = feed_id(kp)
      key = "%private-root=.sha256"
      root = private_root(key)

      {:ok, view, _html} = live(conn, "/post/" <> Base.url_encode64(key, padding: false))

      view
      |> seed(%{status: :ok, self_id: self_id, not_found: false, root: root, replies: []})

      with_publish_capture(fn ->
        view |> element(~s(button[aria-label="Like"])) |> render_click()

        assert_receive {:published, content}
        assert PrivateBox.private?(content)
        refute content =~ key

        assert {:ok, json} = PrivateBox.decrypt(content, kp.secret)

        assert %{
                 "type" => "vote",
                 "vote" => %{"link" => ^key, "value" => 1},
                 "recps" => recps
               } = Jason.decode!(json)

        assert recps == [root["value"]["author"], self_id]
      end)
    end
  end

  describe "the private composer" do
    test "a post is boxed for the chosen feeds and the author", %{conn: conn} do
      kp = keypair()
      self_id = feed_id(kp)
      peer = keypair()
      peer_id = feed_id(peer)

      {:ok, view, _html} = live(conn, "/")
      render_click(view, "view", %{"v" => "private"})

      view |> seed(%{all_contacts: [peer_id], self_id: self_id, status: :ok})

      with_publish_capture(fn ->
        view
        |> form("#compose", %{"body" => "secret plans", "recipients" => [peer_id]})
        |> render_submit()

        assert_receive {:published, content}
        assert PrivateBox.private?(content)
        refute content =~ "secret plans"

        assert {:ok, json} = PrivateBox.decrypt(content, kp.secret)

        assert %{"type" => "post", "text" => "secret plans", "recps" => recps} =
                 Jason.decode!(json)

        assert recps == [peer_id, self_id]
      end)
    end
  end

  describe "thread structure" do
    test "a reply names the message it answers as its branch", %{conn: conn} do
      kp = keypair()
      self_id = feed_id(kp)
      key = "%thread-root=.sha256"
      target_key = "%thread-answer=.sha256"
      author = "@vkdMlsuBgzzo5eLS3LZLdqnBpZ26OauJOMIq9gQ2E7E=.ed25519"

      root = %{
        "key" => key,
        "value" => %{
          "author" => author,
          "timestamp" => 1_700_000_000_000,
          "content" => %{"type" => "post", "text" => "the thing"}
        }
      }

      target = %{
        "key" => target_key,
        "value" => %{
          "author" => author,
          "timestamp" => 1_700_000_060_000,
          "content" => %{"type" => "post", "text" => "first answer"}
        }
      }

      {:ok, view, _html} = live(conn, "/post/" <> Base.url_encode64(key, padding: false))

      view
      |> seed(%{
        status: :ok,
        self_id: self_id,
        not_found: false,
        root: root,
        replies: [target]
      })

      with_publish_capture(fn ->
        render_click(view, "reply-to", %{"key" => target_key})
        render_change(view, "reply-draft", %{"body" => "a nested answer"})
        render_submit(view, "reply", %{})

        assert_receive {:published, content}
        # The root names the thread; the branch names the reply this one
        # answers, so every client nests it under that message.
        assert content["root"] == key
        assert content["branch"] == target_key
        refute Map.has_key?(content, "fork")
        refute PrivateBox.private?(content)
      end)
    end
  end
end
