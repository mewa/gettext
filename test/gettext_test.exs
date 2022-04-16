defmodule GettextTest.TranslatorWithDuckInterpolator.Interpolator do
  @behaviour Gettext.Interpolation

  @impl Gettext.Interpolation
  def runtime_interpolate(message, bindings),
    do: {:ok, "quack #{message} #{inspect(bindings)} quack"}

  @impl Gettext.Interpolation
  defmacro compile_interpolate(_message_type, message, bindings) do
    quote do
      {:ok, "quack #{unquote(message)} #{inspect(unquote(bindings))} quack"}
    end
  end

  @impl Gettext.Interpolation
  def message_format, do: "duck-format"
end

defmodule GettextTest.TranslatorWithDuckInterpolator do
  use Gettext.Backend,
    otp_app: :test_application,
    interpolation: GettextTest.TranslatorWithDuckInterpolator.Interpolator,
    priv: "test/fixtures/single_messages"
end

defmodule GettextTest do
  use ExUnit.Case

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias GettextTest.Backend

  describe "get_locale/0,1" do
    test "returns \"en\" as the default" do
      assert Gettext.get_locale() == "en"
      assert Gettext.get_locale(Backend) == "en"
    end

    test "gets the locale set by put_locale/2" do
      # First, we set the local for just one backend:
      Gettext.put_locale(Backend, "pt_BR")

      # Now, let's check that only that backend was affected.
      assert Gettext.get_locale(Backend) == "pt_BR"
      assert Gettext.get_locale() == "en"

      # Now, let's change the global locale:
      Gettext.put_locale("it")

      # Let's check that the global locale was affected and that get_locale/1
      # returns the global locale, but only for backends that have no
      # backend-specific locale set.
      assert Gettext.get_locale() == "it"
      assert Gettext.get_locale(Backend) == "pt_BR"
    end

    test "uses the default locale of the :gettext application" do
      global_default = Application.get_env(:gettext, :default_locale)

      try do
        Application.put_env(:gettext, :default_locale, "fr")
        assert Gettext.get_locale() == "fr"
        assert Gettext.get_locale(Backend) == "fr"
      after
        Application.put_env(:gettext, :default_locale, global_default)
      end
    end
  end

  describe "put_locale/2" do
    test "only accepts binaries" do
      msg = "put_locale/2 only accepts binary locales, got: :en"

      assert_raise ArgumentError, msg, fn ->
        Gettext.put_locale(Backend, :en)
      end
    end
  end

  describe "with_locale/3" do
    test "doesn't raise if no locale was set (defaulting to 'en')" do
      Process.delete(Backend)

      Gettext.with_locale(Backend, "it", fn ->
        assert Gettext.gettext(Backend, "Hello world") == "Ciao mondo"
      end)

      assert Gettext.get_locale(Backend) == "en"
    end

    test "runs a function with a given locale and returns the returned value" do
      Gettext.put_locale(Backend, "fr")
      # no 'fr' message
      assert Gettext.gettext(Backend, "Hello world") == "Hello world"

      res =
        Gettext.with_locale(Backend, "it", fn ->
          assert Gettext.gettext(Backend, "Hello world") == "Ciao mondo"
          :foo
        end)

      assert Gettext.get_locale(Backend) == "fr"
      assert res == :foo
    end

    test "resets the locale even if the given function raises" do
      Gettext.put_locale(Backend, "fr")

      assert_raise RuntimeError, fn ->
        Gettext.with_locale(Backend, "it", fn -> raise "foo" end)
      end

      assert Gettext.get_locale(Backend) == "fr"

      catch_throw(Gettext.with_locale(Backend, "it", fn -> throw(:foo) end))
      assert Gettext.get_locale(Backend) == "fr"
    end
  end

  describe "known_locales/1" do
    test "returns all the locales for which a backend has PO files" do
      assert Gettext.known_locales(Backend) == ["it", "ja"]
      assert Gettext.known_locales(GettextTest.BackendWithAllowedLocalesAtom) == ["es"]
      assert Gettext.known_locales(GettextTest.BackendWithAllowedLocalesString) == ["es"]
    end
  end

  test "a custom default_domain can be set for a backend" do
    Code.eval_quoted(
      quote do
        defmodule DefaultDomainTest do
          use Gettext, backend: GettextTest.BackendWithDefaultDomain

          def test("Invalid email address"), do: gettext("Invalid email address")
          def test("Hello world"), do: gettext("Hello world")
        end
      end
    )

    Gettext.put_locale("it")

    assert apply(DefaultDomainTest, :test, ["Invalid email address"]) ==
             "Indirizzo email non valido"

    assert apply(DefaultDomainTest, :test, ["Hello world"]) == "Hello world"
  end

  test "MissingBindingsError log messages" do
    assert capture_log(fn ->
             Gettext.pgettext(Backend, "test", "Hello %{name}, missing message!", %{})
           end) =~
             "missing Gettext bindings: [:name] (backend GettextTest.Backend," <>
               " locale \"en\", domain \"default\", msgctxt \"test\", msgid \"Hello " <>
               "%{name}, missing message!\")"
  end

  describe "*gettext functions (singular)" do
    setup do
      Gettext.put_locale(Backend, "it")
      :ok
    end

    test "gettext/2" do
      assert Gettext.gettext(Backend, "Hello world") == "Ciao mondo"
      assert Gettext.gettext(Backend, "Nonexistent") == "Nonexistent"
    end

    test "dgettext/4" do
      msgid = "Invalid email address"
      assert Gettext.dgettext(Backend, "errors", msgid) == "Indirizzo email non valido"

      assert Gettext.dgettext(Backend, "foo", "Foo") == "Foo"

      log =
        capture_log(fn ->
          assert Gettext.dgettext(Backend, "interpolations", "Hello %{name}", %{}) ==
                   "Ciao %{name}"
        end)

      assert log =~ "[error] missing Gettext bindings: [:name]"
    end

    test "pgettext/3" do
      assert Gettext.pgettext(Backend, "test", "Hello world") == "Ciao mondo"
      assert Gettext.pgettext(Backend, "test", "Nonexistent") == "Nonexistent"
    end

    test "dpgettext/4" do
      assert Gettext.dpgettext(Backend, "default", "test", "Hello world") ==
               "Ciao mondo"
    end
  end

  describe "*ngettext functions (plural)" do
    setup do
      Gettext.put_locale(Backend, "it")
      :ok
    end

    test "ngettext/5" do
      msgid = "One cake, %{name}"
      msgid_plural = "%{count} cakes, %{name}"
      assert Gettext.ngettext(Backend, msgid, msgid_plural, 1, %{name: "Meg"}) == "One cake, Meg"
      assert Gettext.ngettext(Backend, msgid, msgid_plural, 5, %{name: "Meg"}) == "5 cakes, Meg"
    end

    test "dngettext/6" do
      msgid = "You have one message, %{name}"
      msgid_plural = "You have %{count} messages, %{name}"

      assert Gettext.dngettext(Backend, "interpolations", msgid, msgid_plural, 1, %{name: "Meg"}) ==
               "Hai un messaggio, Meg"

      assert Gettext.dngettext(Backend, "interpolations", msgid, msgid_plural, 5, %{name: "Meg"}) ==
               "Hai 5 messaggi, Meg"

      assert Gettext.dngettext(Backend, "interpolations", "Month", "%{count} months", 5) ==
               "5 mesi"
    end

    test "pngettext/6" do
      msgctxt = "test"
      msgid = "One cake, %{name}"
      msgid_plural = "%{count} cakes, %{name}"

      assert Gettext.pngettext(Backend, msgctxt, msgid, msgid_plural, 1, %{name: "Meg"}) ==
               "One cake, Meg"

      assert Gettext.pngettext(Backend, msgctxt, msgid, msgid_plural, 5, %{name: "Meg"}) ==
               "5 cakes, Meg"
    end

    test "dpngettext/6" do
      msgid = "You have one message, %{name}"
      msgid_plural = "You have %{count} messages, %{name}"

      assert Gettext.dpngettext(Backend, "interpolations", "test", msgid, msgid_plural, 1, %{
               name: "Meg"
             }) ==
               "Hai un messaggio, Meg"

      assert Gettext.dpngettext(Backend, "interpolations", "test", msgid, msgid_plural, 5, %{
               name: "Meg"
             }) ==
               "Hai 5 messaggi, Meg"

      assert Gettext.dpngettext(
               Backend,
               "default",
               "test",
               "One new email",
               "%{count} new emails",
               5,
               %{name: "Meg"}
             ) == "5 nuove test email"
    end
  end

  test "the d?n?gettext functions support kw list for interpolations" do
    Gettext.put_locale(Backend, "it")
    assert Gettext.gettext(Backend, "Hello %{name}", name: "José") == "Hello José"
  end

  test "uses custom interpolator" do
    assert Gettext.gettext(GettextTest.TranslatorWithDuckInterpolator, "foo") ==
             "quack foo %{} quack"
  end

  test "use Gettext for defining backends is deprecated" do
    stderr =
      capture_io(:stderr, fn ->
        Code.eval_quoted(
          quote do
            defmodule DeprecatedWayOfDefiningBackend do
              use Gettext, otp_app: :my_app
            end
          end
        )
      end)

    assert stderr =~ "defining a Gettext backend by calling"
    assert stderr =~ "is deprecated"
  end

  defmodule GettextTest.PersistentTermRepo do
    @behaviour Gettext.Repo

    use Agent

    def start_link(opts) do
      name = Keyword.get(opts, :name, __MODULE__)
      Agent.start_link(fn -> nil end, name: name)
    end

    def set_msgstr(msgstr, name \\ __MODULE__) do
      Agent.update(name, fn _ -> msgstr end)
    end

    def get_msgstr(name \\ __MODULE__) do
      case Agent.get(name, & &1) do
        nil -> :not_found
        msgstr -> {:ok, msgstr}
      end
    end

    @impl Gettext.Repo
    def init(name) when is_atom(name) do
      name
    end

    def init(_), do: __MODULE__

    @impl Gettext.Repo
    def get_translation(_locale, _domain, _msgctxt, _msgid, name) do
      get_msgstr(name)
    end

    @impl Gettext.Repo
    def get_plural_translation(_locale, _domain, _msgctxt, _msgid, _plural_form, name) do
      get_msgstr(name)
    end
  end

  defmodule GettextTest.TranslatorWithRuntimeRepo do
    use Gettext,
      otp_app: :test_application,
      repo: GettextTest.PersistentTermRepo
  end

  defmodule GettextTest.TranslatorWithConfigurableRuntimeRepo do
    use Gettext,
      otp_app: :test_application,
      repo: {GettextTest.PersistentTermRepo, :gettext_test_repo_name}
  end

  test "uses runtime repo" do
    import GettextTest.TranslatorWithRuntimeRepo, only: [lgettext: 5, lngettext: 7]

    {:ok, _repo} = GettextTest.PersistentTermRepo.start_link([])

    get_singular = fn -> lgettext("it", "default", nil, "Hello world", %{}) end

    get_plural = fn ->
      lngettext(
        "it",
        "errors",
        nil,
        "There was an error",
        "There were %{count} errors",
        1,
        %{}
      )
    end

    assert get_singular.() == {:ok, "Ciao mondo"}
    assert get_plural.() == {:ok, "C'è stato un errore"}

    GettextTest.PersistentTermRepo.set_msgstr("Runtime")

    assert get_singular.() == {:ok, "Runtime"}
    assert get_plural.() == {:ok, "Runtime"}
  end

  test "runtime repo can be initialized with config value" do
    import GettextTest.TranslatorWithConfigurableRuntimeRepo, only: [lgettext: 5]

    {:ok, _repo1} = GettextTest.PersistentTermRepo.start_link([])
    {:ok, _repo2} = GettextTest.PersistentTermRepo.start_link(name: :gettext_test_repo_name)

    GettextTest.PersistentTermRepo.set_msgstr("Not this one")
    GettextTest.PersistentTermRepo.set_msgstr("This one", :gettext_test_repo_name)

    assert lgettext("it", "default", nil, "Hello world", %{}) == {:ok, "This one"}
  end
end
