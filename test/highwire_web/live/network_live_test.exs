defmodule HighWireWeb.NetworkLiveTest do
  use HighWireWeb.ConnCase

  import Phoenix.LiveViewTest

  alias HighWire.SSB.Network
  alias HighWireWeb.NetworkLive

  setup do
    # A stale overrides file from another run would move the pressed
    # profile out from under these assertions.
    File.rm(Network.path())
    :ok
  end

  describe "nav badge" do
    test "links to the network page, not settings", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/network")

      # The badge is the general entry point; it used to point at
      # settings, which no longer holds any network controls.
      assert html =~ ~s(href="/network")
      assert html =~ ~s(aria-label="Network")
    end
  end

  describe "network profile switcher" do
    test "renders both profiles with the current one pressed", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/network")

      assert html =~ "Which network"
      assert html =~ "Network set to:"
      assert html =~ "Development"
      assert html =~ "Mainnet"
      assert html =~ ~s(phx-click="switch_network")

      # Exactly one control per profile, the active one pressed — a
      # fresh overrides file leaves the development profile current.
      assert [_] = Regex.scan(~r/phx-value-network="mainnet"/, html)
      assert [_] = Regex.scan(~r/phx-value-network="dev"/, html)
      assert html =~ ~r/phx-value-network="dev"[^>]*aria-pressed="true"/
      assert html =~ ~r/phx-value-network="mainnet"[^>]*aria-pressed="false"/
    end

    test "switching while the engine is disabled fails with an explanation", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/network")

      view
      |> element("button[phx-value-network=mainnet]")
      |> render_click()

      # The disabled-engine answer can land before the first render, so
      # assert the settled outcome rather than the transient notice.
      Process.sleep(200)
      assert render(view) =~ "disabled in this configuration"
    end

    test "re-clicking the active profile is a no-op", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/network")

      html =
        view
        |> element("button[phx-value-network=dev]")
        |> render_click()

      refute html =~ "Switching to"
    end
  end

  describe "dialer controls (engine down)" do
    test "are present but disabled when the engine is not answering", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/network")

      assert html =~ "Dialer"
      assert html =~ "Turn auto-dial on"
      assert html =~ "Dial now"
      assert html =~ "auto-dial unknown"

      # A cache-seeded report has no live engine to command, so the
      # controls disable and the notice says the numbers are the cache's.
      assert html =~ "The local service is not answering"
      assert html =~ ~r/<button[^>]*phx-click="dialer-toggle"[^>]*disabled/
      assert html =~ ~r/<button[^>]*phx-click="dialer-trigger"[^>]*disabled/
    end
  end

  describe "known peers (engine down)" do
    test "sections still open on the cached report, each saying what it lacks", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/network")

      # The page no longer hides behind a nil report: it opens on the
      # peer cache, so every section stands and states what it knows.
      assert html =~ "The local service is not answering"
      assert html =~ "Connections ·"
      assert html =~ "No peers connected."
      assert html =~ "Known peers · 0"
      assert html =~ "The address book is empty"
      assert html =~ "Recent dials"
    end

    test "the rail jump-links every section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/network")

      for href <- ~w(which-network dialer constellation connections known-peers dials) do
        assert html =~ ~s(href="##{href}")
      end
    end
  end

  # The engine cannot run under test, so the report-present half of the
  # page is rendered directly: build the assigns a live session would
  # hold and call render/1. Same template, same helpers.
  describe "render with a live report" do
    test "shows connections, the address book, and recent dials" do
      html =
        render_with_report(%{
          "enabled" => true,
          "cap" => 8,
          "connections" => ["@alice.ed25519"],
          "lanCandidates" => 2,
          "autoconnectCandidates" => 5,
          "knownPeers" => [
            %{
              "address" => "net:192.168.1.10:8008~shs:bobkey",
              "source" => "pub",
              "autoconnect" => true
            },
            %{"address" => "net:10.0.0.2:8008~shs:carolkey", "autoconnect" => false}
          ],
          "dialTry" => [
            %{"addr" => "net:192.168.1.10:8008~shs:bobkey", "attempts" => 0, "lastTry" => 1},
            %{"addr" => "net:10.0.0.2:8008~shs:carolkey", "attempts" => 3, "lastTry" => 1}
          ]
        })

      # Dialer: on, with the off toggle offered.
      assert html =~ "auto-dial on"
      assert html =~ "Turn auto-dial off"
      assert html =~ "Dial now"
      refute html =~ ~r/<button[^>]*phx-click="dialer-toggle"[^>]*disabled/

      # Connections: one row, address shortened to the 9-char id form.
      assert html =~ "Connections · 1 / 8"
      assert html =~ "alice.ed2"

      # Known peers: host:port shown, full address in the title,
      # source and auto/manual badges.
      assert html =~ "Known peers · 2"
      assert html =~ "192.168.1.10:8008"
      assert html =~ ~s(title="net:192.168.1.10:8008~shs:bobkey")
      assert html =~ "pub"
      assert html =~ "auto"
      assert html =~ "manual"

      # Recent dials: ok vs failing counts.
      assert html =~ "Recent dials"
      assert html =~ "ok"
      assert html =~ "3 fails"
    end

    test "each known peer shows an identicon, its name, and where it lives" do
      report = %{
        "enabled" => true,
        "connections" => [],
        "dialTry" => [],
        "knownPeers" => [
          %{"address" => "net:192.168.1.10:8008~shs:bobkey", "autoconnect" => true}
        ]
      }

      bob = "@bobkey.ed25519"

      html =
        render_with_report(report, %{profiles: %{bob => %{name: "Bobs Pub", image: nil}}})

      # The alias — not the raw key — names the row, over the host:port;
      # the full address stays in the hover title.
      assert html =~ "Bobs Pub"
      assert html =~ "192.168.1.10:8008"
      assert html =~ ~s(title="net:192.168.1.10:8008~shs:bobkey")
      refute html =~ "bobkey.ed"

      # The identicon is keyed by the feed id the address carries, so it
      # is that peer's tile, not a placeholder.
      assert html =~ HighWire.Avatar.identicon_url(bob)

      # Without an alias the row falls back to the short id, not the
      # full base64 key.
      unaliased = render_with_report(report)
      assert unaliased =~ "bobkey.ed"
    end

    test "auto-dial off offers the on toggle" do
      html = render_with_report(%{"enabled" => false, "connections" => [], "dialTry" => []})

      assert html =~ "auto-dial off"
      assert html =~ "Turn auto-dial on"
    end

    test "known peers beyond the cap are truncated with a count line" do
      peers =
        for i <- 1..52 do
          %{"address" => "net:10.0.0.#{i}:8008~shs:key#{i}", "autoconnect" => true}
        end

      html =
        render_with_report(%{
          "enabled" => true,
          "connections" => [],
          "knownPeers" => peers,
          "dialTry" => []
        })

      assert html =~ "Known peers · 52"
      assert html =~ "Showing first 50 of 52"
      # Row 51's address is not rendered.
      refute html =~ "10.0.0.51:8008"
      refute html =~ "10.0.0.52:8008"
    end

    test "marks known peers that never answered as no reply" do
      peers = [%{"address" => "net:dead.example:8008~shs:key", "autoconnect" => true}]

      html =
        render_with_report(
          %{
            "enabled" => true,
            "connections" => [],
            "knownPeers" => peers,
            "dialTry" => []
          },
          %{
            peer_meta: %{
              "net:dead.example:8008~shs:key" => %{"dial_attempts" => 5, "dial_ok_at" => 0}
            }
          }
        )

      assert html =~ "no reply"
      assert html =~ "dialed 5 times"
    end

    test "does not badge a peer with fewer than the threshold of failures" do
      peers = [%{"address" => "net:transient.example:8008~shs:key", "autoconnect" => true}]

      html =
        render_with_report(
          %{
            "enabled" => true,
            "connections" => [],
            "knownPeers" => peers,
            "dialTry" => []
          },
          %{
            peer_meta: %{
              "net:transient.example:8008~shs:key" => %{"dial_attempts" => 1, "dial_ok_at" => 0}
            }
          }
        )

      refute html =~ "no reply"
    end

    test "does not badge a peer that has answered at least once" do
      peers = [%{"address" => "net:flap.example:8008~shs:key", "autoconnect" => true}]

      html =
        render_with_report(
          %{
            "enabled" => true,
            "connections" => [],
            "knownPeers" => peers,
            "dialTry" => []
          },
          %{
            peer_meta: %{
              "net:flap.example:8008~shs:key" => %{"dial_attempts" => 10, "dial_ok_at" => 1_000}
            }
          }
        )

      refute html =~ "no reply"
    end

    test "empty sections say so" do
      html =
        render_with_report(%{
          "enabled" => true,
          "connections" => [],
          "knownPeers" => [],
          "dialTry" => []
        })

      assert html =~ "No peers connected."
      assert html =~ "The address book is empty"
      assert html =~ "Nothing dialed yet."
      assert html =~ "Quiet sky"
    end

    test "the constellation draws each rung of the connectivity ladder" do
      html =
        render_with_report(%{
          "enabled" => true,
          "connections" => ["@alice.ed25519"],
          "knownPeers" => [
            %{"address" => "net:192.168.1.10:8008~shs:bobkey", "autoconnect" => true}
          ],
          "dialTry" => [
            %{"addr" => "net:10.0.0.2:8008~shs:carolkey", "attempts" => 3, "lastTry" => 1},
            %{"addr" => "net:10.0.0.3:8008~shs:davekey", "attempts" => 0, "lastTry" => 1}
          ]
        })

      assert html =~ ~s(id="constellation")
      # Only a session we hold is green; an address whose last handshake
      # worked is blue; one we are backing off after is an amber open
      # ring — still trying, so it carries less ink than a state we
      # have attained; a book entry with no dial record is plain grey.
      assert html =~ ~s(class="fill-dot-ok gossip-node-flare")
      assert html =~ ~s(class="fill-info")
      assert html =~ ~s(class="fill-none stroke-warn")
      assert html =~ ~s(r="3.5")
      assert html =~ "10.0.0.2:8008"
      assert html =~ "10.0.0.3:8008"
      assert html =~ "192.168.1.10:8008"
      assert html =~ ~s(role="img")
      assert html =~ "1 connected"
      refute html =~ "Quiet sky"
    end

    test "constellation nodes hold their positions across reordering" do
      peers =
        for i <- 1..5 do
          %{"address" => "net:10.0.0.#{i}:8008~shs:key#{i}", "autoconnect" => true}
        end

      sky = fn known ->
        html =
          render_with_report(%{
            "enabled" => true,
            "connections" => [],
            "dialTry" => [],
            "knownPeers" => known
          })

        [_, block] =
          Regex.run(~r/(<svg[^>]*viewBox="0 0 640 350"[^>]*>.*?<\/svg>)/s, html)

        Regex.scan(~r/cx="([\d.]+)" cy="([\d.]+)" r="3\.5"/, block)
        |> Enum.map(fn [_, x, y] -> {x, y} end)
        |> MapSet.new()
      end

      assert sky.(peers) == sky.(Enum.reverse(peers))
      assert MapSet.size(sky.(peers)) == 5
    end

    test "two keys hashing to nearly the same spot still draw as two dots" do
      # Two ids whose hash buckets sit within a few slices of each
      # other — the near-tie the spot-claiming pass exists to
      # separate. Found at run time, so the test rides whatever
      # phash2 does rather than pinning a particular pair.
      near =
        for i <- 1..300 do
          {:erlang.phash2("@near#{i}.ed25519", 10_000), "@near#{i}.ed25519"}
        end

      [{_b1, one}, {_b2, two}] =
        near
        |> Enum.sort()
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.find(fn [{b1, _}, {b2, _}] -> b2 - b1 <= 100 end)

      html =
        render_with_report(%{
          "enabled" => true,
          "connections" => [one, two],
          "dialTry" => [],
          "knownPeers" => []
        })

      assert html =~ "connected · 2"

      [_, block] = Regex.run(~r/(<svg[^>]*viewBox="0 0 640 350"[^>]*>.*?<\/svg>)/s, html)

      # Unclaimed, these two land a pixel or two apart — five peers
      # reading as four dots. Now each keeps its own spot.
      assert [{x1, y1}, {x2, y2}] =
               Regex.scan(~r/cx="([\d.]+)" cy="([\d.]+)" r="5"/, block)
               |> Enum.map(fn [_, x, y] -> {String.to_float(x), String.to_float(y)} end)

      assert :math.sqrt((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1)) >= 10.0
    end

    test "the constellation tethers autoconnect peers and leaves retries on the ring" do
      html =
        render_with_report(%{
          "enabled" => true,
          "connections" => [],
          "dialTry" => [
            %{"addr" => "net:10.0.0.2:8008~shs:carolkey", "attempts" => 1, "lastTry" => 1}
          ],
          "knownPeers" => [
            %{"address" => "net:192.168.1.10:8008~shs:bobkey", "autoconnect" => true},
            %{"address" => "net:10.9.9.9:8008~shs:manualkey", "autoconnect" => false}
          ]
        })

      # A peer we are not connected to gets a mark on its rung and no
      # spoke — a sky full of spokes read as fireworks, not as a
      # network. Retrying peers are open rings, not solid dots, and
      # nothing is tethered out to them. Autoconnect entries in the
      # address book stay dashed; the manual entry floats untethered,
      # its address appearing only as a node tooltip and a list row.
      assert html =~ ~s(class="fill-none stroke-warn")
      refute html =~ ~r/<line[^>]*stroke-warn/s
      assert html =~ "stroke-dasharray"
      assert html =~ "10.9.9.9:8008"
      # Hit targets exist behind the clickable nodes.
      assert html =~ ~s(phx-click="sky-select")
    end

    test "a peer is drawn once, on the innermost rung it qualifies for" do
      carol = "net:10.0.0.2:8008~shs:carolkey"
      dave = "net:10.0.0.9:8008~shs:davekey"

      html =
        render_with_report(%{
          "enabled" => true,
          "connections" => ["@carolkey.ed25519"],
          "dialTry" => [
            %{"addr" => carol, "attempts" => 0, "lastTry" => 1},
            %{"addr" => dave, "attempts" => 4, "lastTry" => 1}
          ],
          "knownPeers" => [
            %{"address" => carol, "autoconnect" => true},
            %{"address" => dave, "autoconnect" => true}
          ]
        })

      # Carol holds a session, so her dial row and her address-book row
      # are both dropped rather than drawn again on an outer rung; Dave
      # has dial history, so his book entry is dropped too.
      assert html =~ "connected · 1"
      assert html =~ "reached · 0"
      assert html =~ "retrying · 1"
      assert html =~ "never tried · 0"

      refute html =~ ~s(key="ok-#{carol}")
      refute html =~ ~s(key="known-#{carol}")
      refute html =~ ~s(key="known-#{dave}")
      assert html =~ ~s(key="retry-#{dave}")
    end

    test "the same identity at two addresses is still one dot" do
      html =
        render_with_report(%{
          "enabled" => true,
          "connections" => [],
          "knownPeers" => [],
          "dialTry" => [
            %{"addr" => "net:10.0.0.2:8008~shs:carolkey", "attempts" => 1, "lastTry" => 2},
            %{"addr" => "net:10.0.0.7:8008~shs:carolkey", "attempts" => 5, "lastTry" => 1}
          ]
        })

      # The most recently tried address wins; the other is the same peer.
      assert html =~ "retrying · 1"
      assert html =~ ~s(key="retry-net:10.0.0.2:8008~shs:carolkey")
      refute html =~ ~s(key="retry-net:10.0.0.7:8008~shs:carolkey")
    end

    test "each ring names itself and counts what it carries" do
      html =
        render_with_report(%{
          "enabled" => true,
          "connections" => ["peer-one"],
          "dialTry" => [
            %{"addr" => "net:10.0.0.2:8008~shs:carolkey", "attempts" => 2, "lastTry" => 1}
          ],
          "knownPeers" => []
        })

      assert html =~ "connected · 1"
      assert html =~ "reached · 0"
      assert html =~ "retrying · 1"
      assert html =~ "never tried · 0"
    end

    test "peer names are drawn but hidden until the node is hovered" do
      html = render_with_report(%{"enabled" => true, "connections" => ["peer-one"]})

      assert html =~ "sky-label"
      assert html =~ "opacity-0 transition-opacity group-hover:opacity-100"
      # A hidden name must not become an invisible hover zone.
      assert html =~ ~s(pointer-events="none")
    end

    test "selecting a peer highlights its node ring and list row" do
      report = %{
        "enabled" => true,
        "connections" => [],
        "dialTry" => [],
        "knownPeers" => [
          %{"address" => "net:192.168.1.10:8008~shs:bobkey", "autoconnect" => true}
        ]
      }

      unselected = render_with_report(report)
      refute unselected =~ "stroke-accent"
      refute unselected =~ ~s(data-target="net:)

      selected =
        render_with_report(report, %{selected: "net:192.168.1.10:8008~shs:bobkey"})

      assert selected =~ "stroke-accent"
      # The scroll hook carries the selection to the browser.
      assert selected =~ ~s(phx-hook="SkyScroll")
      assert selected =~ ~s(data-target="net:192.168.1.10:8008~shs:bobkey")
    end

    test "sky-select toggles the selection" do
      {:ok, socket} = NetworkLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{})
      addr = "net:192.168.1.10:8008~shs:bobkey"

      {:noreply, socket} =
        NetworkLive.handle_event("sky-select", %{"addr" => addr}, socket)

      assert socket.assigns.selected == addr

      # A second click on the same peer retires the selection.
      {:noreply, socket} =
        NetworkLive.handle_event("sky-select", %{"addr" => addr}, socket)

      assert socket.assigns.selected == nil
    end

    test "live nodes flare with the gossip pulse and link to profiles" do
      html =
        render_with_report(
          %{
            "enabled" => true,
            "connections" => ["@alice.ed25519"],
            "dialTry" => [],
            "knownPeers" => []
          },
          %{gossip: %{connected: 1, pulse: 4}}
        )

      assert html =~ "gossip-node-flare"
      assert html =~ ~s(key="4")
      assert html =~ "/profile?"
    end

    test "the rail jump-links every rendered section" do
      html =
        render_with_report(%{
          "enabled" => true,
          "connections" => [],
          "knownPeers" => [],
          "dialTry" => []
        })

      assert html =~ ~s(href="#which-network")
      assert html =~ ~s(href="#dialer")
      assert html =~ ~s(href="#constellation")
      assert html =~ ~s(href="#connections")
      assert html =~ ~s(href="#known-peers")
      assert html =~ ~s(href="#dials")
    end
  end

  describe "suppression control" do
    test "offers a preview and applies it with a confirm step" do
      html =
        render_with_report(%{
          "enabled" => true,
          "connections" => [],
          "knownPeers" => [%{"address" => "net:127.0.0.1:8020~shs:key", "autoconnect" => true}],
          "dialTry" => []
        })

      assert html =~ "Preview suppression"
      assert html =~ ~s(phx-click="suppress-preview")
      refute html =~ ~s(phx-click="suppress-apply")
    end

    test "previewing lists the counts it would suppress" do
      html =
        render_with_report(
          %{
            "enabled" => true,
            "connections" => [],
            "knownPeers" => [
              %{"address" => "net:127.0.0.1:8020~shs:key", "autoconnect" => true},
              %{"address" => "net:room.example:8008~shs:key", "autoconnect" => true}
            ],
            "dialTry" => []
          },
          %{
            suppress_preview: %{
              addrs: ["net:127.0.0.1:8020~shs:key"],
              counts: %{loopback: 1, total: 1, book: 2}
            }
          }
        )

      assert html =~ "Suppress 1 &amp; restart"
      assert html =~ "1 loopback"
      assert html =~ "1 to suppress"
      assert html =~ ~s(phx-click="suppress-apply")
      assert html =~ ~s(phx-click="suppress-cancel")
    end

    test "an empty preview says there is nothing to suppress" do
      html =
        render_with_report(
          %{
            "enabled" => true,
            "connections" => [],
            "knownPeers" => [
              %{"address" => "net:room.example:8008~shs:key", "autoconnect" => true}
            ],
            "dialTry" => []
          },
          %{suppress_preview: %{addrs: [], counts: %{total: 0}}}
        )

      assert html =~ "Nothing to suppress"
    end

    test "previewing classifies the address book on disk, writing nothing" do
      home = with_temp_home()

      File.write!(Path.join([home, ".ssberl", "conn.json"]), """
      {
          "net:127.0.0.1:8020~shs:key": {
              "autoconnect": true
          },
          "net:room.example:8008~shs:key2": {
              "autoconnect": true
          }
      }
      """)

      {:ok, socket} = NetworkLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{})
      socket = Phoenix.Component.assign(socket, :peer_meta, %{})

      {:noreply, socket} = NetworkLive.handle_event("suppress-preview", %{}, socket)

      assert %{addrs: ["net:127.0.0.1:8020~shs:key"], counts: counts} =
               socket.assigns.suppress_preview

      assert counts[:loopback] == 1

      # Preview only: the book is untouched.
      assert File.read!(Path.join([home, ".ssberl", "conn.json"])) =~ ~s("autoconnect": true)

      {:noreply, socket} = NetworkLive.handle_event("suppress-cancel", %{}, socket)
      assert socket.assigns.suppress_preview == nil
    end

    test "a book entry already suppressed is not listed again" do
      home = with_temp_home()

      File.write!(Path.join([home, ".ssberl", "conn.json"]), """
      {
          "net:127.0.0.1:8020~shs:key": {
              "autoconnect": false
          }
      }
      """)

      {:ok, socket} = NetworkLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{})
      socket = Phoenix.Component.assign(socket, :peer_meta, %{})

      {:noreply, socket} = NetworkLive.handle_event("suppress-preview", %{}, socket)

      assert %{addrs: [], counts: counts} = socket.assigns.suppress_preview
      assert counts[:total] == 0
    end
  end

  # Point :application_dir at a throwaway home for the one suite that
  # reads the address book off disk.
  defp with_temp_home do
    home = Path.join(System.tmp_dir!(), "netlive_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, ".ssberl"))
    previous = Application.get_env(:highwire, :application_dir)
    Application.put_env(:highwire, :application_dir, home)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:highwire, :application_dir)
        dir -> Application.put_env(:highwire, :application_dir, dir)
      end

      File.rm_rf!(home)
    end)

    home
  end

  # The assigns a connected session would hold, with only the report
  # swapped out — render_with_report/2 lets a test override anything.
  defp render_with_report(report, overrides \\ %{}) do
    assigns =
      Map.merge(
        %{
          __changed__: nil,
          page_title: "Network",
          status: :ok,
          profiles: %{},
          report: report,
          peer_meta: %{},
          active: true,
          tick_timer: nil,
          network: :dev,
          net_status: :ready,
          switching: false,
          switch_notice: nil,
          polls: 0,
          dial_notice: nil,
          dialing: false,
          known_peers_cap: 50,
          selected: nil,
          gossip: %{connected: 0, pulse: 0},
          suppress_preview: nil,
          suppress_notice: nil,
          suppressing: false
        },
        overrides
      )

    NetworkLive.render(assigns) |> Phoenix.LiveViewTest.rendered_to_string()
  end
end
