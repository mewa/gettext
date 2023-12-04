defmodule Gettext.ExtractorTest do
  use ExUnit.Case

  alias Expo.Message
  alias Expo.Messages
  alias Gettext.Extractor

  describe "merge_pot_files/2" do
    @tag :tmp_dir
    test "merges two POT files", %{tmp_dir: tmp_dir} do
      paths = %{
        tomerge: Path.join(tmp_dir, "tomerge.pot"),
        ignored: Path.join(tmp_dir, "ignored.pot"),
        new: Path.join(tmp_dir, "new.pot")
      }

      extracted_po_structs = [
        {paths.tomerge, %Messages{messages: [%Message.Singular{msgid: ["other"], msgstr: [""]}]}},
        {paths.new, %Messages{messages: [%Message.Singular{msgid: ["new"], msgstr: [""]}]}}
      ]

      write_file(paths.tomerge, """
      msgid "foo"
      msgstr ""
      """)

      write_file(paths.ignored, """
      msgid "ignored"
      msgstr ""
      """)

      structs =
        Extractor.merge_pot_files(extracted_po_structs, [paths.tomerge, paths.ignored], [])

      # Unchanged files are not returned
      assert List.keyfind(structs, paths.ignored, 0) == nil

      {_, contents} = List.keyfind(structs, paths.tomerge, 0)

      assert IO.iodata_to_binary(contents) == """
             msgid "foo"
             msgstr ""

             msgid "other"
             msgstr ""
             """

      {_, contents} = List.keyfind(structs, paths.new, 0)
      contents = IO.iodata_to_binary(contents)

      assert contents =~ """
             msgid "new"
             msgstr ""
             """
    end

    @tag :tmp_dir
    test "reports the filename if syntax error", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "syntax_error.pot")

      write_file(path, """
      msgid "foo"

      msgid "bar"
      msgstr ""
      """)

      message = ~r/syntax_error\.pot:3: syntax error before: msgid/

      assert_raise Expo.PO.SyntaxError, message, fn ->
        Extractor.merge_pot_files([{path, %Messages{messages: []}}], [path], [])
      end
    end
  end

  describe "merge_template/2" do
    test "non-autogenerated messages are kept" do
      # No autogenerated messages
      message_1 = %Message.Singular{msgid: ["foo"], msgstr: ["bar"]}
      message_2 = %Message.Singular{msgid: ["baz"], msgstr: ["bong"]}
      message_3 = %Message.Singular{msgid: ["a", "b"], msgstr: ["c", "d"]}
      old = %Messages{messages: [message_1]}
      new = %Messages{messages: [message_2, message_3]}

      assert Extractor.merge_template(old, new, []) == %Messages{
               messages: [message_1, message_2, message_3]
             }
    end

    test "allowed messages are kept" do
      message_1 = %Message.Singular{
        msgid: ["foo"],
        msgstr: ["bar"],
        references: [[{"foo.ex", 1}, {"bar.ex", 1}], [{"baz.ex", 1}]],
        flags: [["elixir-autogen", "elixir-format"]]
      }

      message_2 = %Message.Singular{
        msgid: ["baz"],
        msgstr: ["bong"],
        references: [{"web/static/js/app.js", 10}]
      }

      old = %Messages{messages: [message_1, message_2]}
      new = %Messages{messages: []}

      assert Extractor.merge_template(old, new, excluded_refs_from_purging: ~r{^web/static/}) ==
               %Messages{messages: [message_2]}
    end

    test "obsolete autogenerated messages are discarded" do
      # Autogenerated messages
      message_1 = %Message.Singular{
        msgid: ["foo"],
        msgstr: ["bar"],
        flags: [["elixir-autogen", "elixir-format"]]
      }

      message_2 = %Message.Singular{msgid: ["baz"], msgstr: ["bong"]}
      old = %Messages{messages: [message_1]}
      new = %Messages{messages: [message_2]}

      assert Extractor.merge_template(old, new, []) == %Messages{messages: [message_2]}
    end

    test "matching messages are merged" do
      ts1 = [
        %Message.Singular{
          msgid: ["matching autogenerated"],
          references: [{"foo.ex", 2}],
          flags: [["elixir-autogen"]],
          extracted_comments: ["#. Foo"]
        },
        %Message.Singular{msgid: ["non-matching autogenerated"], flags: [["elixir-autogen"]]},
        %Message.Singular{msgid: ["non-autogenerated"], references: [{"foo.ex", 4}]}
      ]

      ts2 = [
        %Message.Singular{msgid: ["non-matching non-autogenerated"]},
        %Message.Plural{
          msgid: ["matching autogenerated"],
          msgid_plural: ["matching non-autogenerated 2"],
          references: [{"foo.ex", 3}],
          extracted_comments: ["#. Bar"],
          flags: [["elixir-autogen"]]
        }
      ]

      assert Extractor.merge_template(
               %Messages{messages: ts1},
               %Messages{messages: ts2},
               []
             ) ==
               %Messages{
                 messages: [
                   %Message.Plural{
                     msgid: ["matching autogenerated"],
                     msgid_plural: ["matching non-autogenerated 2"],
                     references: [{"foo.ex", 3}],
                     flags: [["elixir-autogen"]],
                     extracted_comments: ["#. Bar"]
                   },
                   %Message.Singular{
                     msgid: ["non-autogenerated"],
                     references: [{"foo.ex", 4}]
                   },
                   %Message.Singular{msgid: ["non-matching non-autogenerated"]}
                 ]
               }
    end

    test "headers are taken from the oldest PO file" do
      po1 = %Messages{
        headers: ["Last-Translator: Foo", "Content-Type: text/plain"],
        messages: []
      }

      po2 = %Messages{headers: ["Last-Translator: Bar"], messages: []}

      assert Extractor.merge_template(po1, po2, []) == %Messages{
               headers: [
                 "Last-Translator: Foo",
                 "Content-Type: text/plain"
               ],
               messages: []
             }
    end

    test "non-empty msgstrs raise an error" do
      po1 = %Messages{messages: [%Message.Singular{msgid: ["foo"], msgstr: ["bar"]}]}
      po2 = %Messages{messages: [%Message.Singular{msgid: ["foo"], msgstr: ["bar"]}]}

      msg = "message with msgid 'foo' has a non-empty msgstr"

      assert_raise Gettext.Error, msg, fn ->
        Extractor.merge_template(po1, po2, [])
      end
    end

    test "order is kept as much as possible" do
      # Old messages are kept in the order we find them (except the ones we
      # remove), and all the new ones are appended after them.
      foo_message = %Message.Singular{msgid: ["foo"], references: [{"foo.ex", 1}]}

      msgid = "Live stream available from %{provider}"

      po1 = %Messages{
        messages: [
          %Message.Singular{msgid: [msgid], references: [{"reminder.ex", 160}]},
          foo_message
        ]
      }

      po2 = %Messages{
        messages: [
          %Message.Singular{msgid: ["new message"]},
          foo_message,
          %Message.Singular{msgid: [msgid], references: [{"live_streaming.ex", 40}]}
        ]
      }

      %Messages{messages: [message_1, ^foo_message, message_2]} =
        Extractor.merge_template(po1, po2, [])

      assert message_1.msgid == [msgid]
      assert message_1.references == [{"live_streaming.ex", 40}]
      assert message_2.msgid == ["new message"]
    end

    test "messages can be ordered alphabetically through the :sort_by_msgid option" do
      # Old and new messages are mixed together and ordered alphabetically.
      foo_message_uppercase = %Message.Singular{msgid: ["FOO"], references: [{"FOO.ex", 1}]}
      foo_message = %Message.Singular{msgid: ["", "foo"], references: [{"foo.ex", 1}]}

      bar_message = %Message.Singular{msgid: ["ba", "r"], references: [{"bar.ex", 1}]}

      baz_message = %Message.Plural{
        msgid: ["b", "az"],
        msgid_plural: ["bazs"],
        references: [{"baz.ex", 1}]
      }

      qux_message = %Message.Singular{msgid: ["qux", ""], references: [{"bar.ex", 1}]}

      po1 = %Messages{
        messages: [
          foo_message_uppercase,
          foo_message,
          qux_message,
          bar_message
        ]
      }

      po2 = %Messages{
        messages: [
          baz_message,
          foo_message,
          bar_message,
          foo_message_uppercase
        ]
      }

      %Messages{messages: messages} =
        Extractor.merge_template(po1, po2, sort_by_msgid: :case_sensitive)

      assert Enum.map(messages, &IO.chardata_to_string(&1.msgid)) == ~w(FOO bar baz foo qux)
    end

    test "messages can be ordered alphabetically through the :sort_by_msgid_case_insensitive option" do
      # Old and new messages are mixed together and ordered alphabetically in a case insensitive fashion.
      foo_1_message = %Message.Singular{msgid: ["foo"], references: [{"foo.ex", 1}]}
      foo_2_message = %Message.Singular{msgid: ["Foo"], references: [{"Foo.ex", 1}]}
      foo_3_message = %Message.Singular{msgid: ["FOO"], references: [{"FOO.ex", 1}]}
      bar_message = %Message.Singular{msgid: ["bar"], references: [{"bar.ex", 1}]}
      qux_message = %Message.Singular{msgid: ["qux"], references: [{"qux.ex", 1}]}

      po1 = %Messages{
        messages: [
          foo_1_message,
          qux_message,
          foo_2_message,
          bar_message,
          foo_3_message
        ]
      }

      po2 = %Messages{
        messages: [
          bar_message,
          foo_1_message,
          bar_message
        ]
      }

      %Messages{messages: messages} =
        Extractor.merge_template(po1, po2, sort_by_msgid: :case_insensitive)

      assert Enum.map(messages, &IO.chardata_to_string(&1.msgid)) == ~w(bar foo Foo FOO qux)
    end
  end

  test "extraction process" do
    refute Extractor.extracting?()
    Extractor.enable()
    assert Extractor.extracting?()

    code = """
    defmodule Gettext.ExtractorTest.MyGettext do
      use Gettext, otp_app: :test_application
    end

    defmodule Gettext.ExtractorTest.MyOtherGettext do
      use Gettext, otp_app: :test_application, priv: "messages"
    end

    defmodule Foo do
      import Gettext.ExtractorTest.MyGettext
      require Gettext.ExtractorTest.MyOtherGettext

      def bar do
        gettext_comment("some comment")
        gettext_comment("some other comment")
        gettext_comment("repeated comment")
        gettext("foo")
        dngettext("errors", "one error", "%{count} errors", 2)
        gettext_comment("one more comment")
        gettext_comment("repeated comment")
        gettext_comment("repeated comment")
        gettext("foo")
        Gettext.ExtractorTest.MyOtherGettext.dgettext("greetings", "hi")
        pgettext("test", "context based message")
      end
    end
    """

    Code.compile_string(code, Path.join(File.cwd!(), "foo.ex"))

    expected = [
      {"priv/gettext/default.pot",
       ~S"""
       msgid ""
       msgstr ""

       #. some comment
       #. some other comment
       #. repeated comment
       #. one more comment
       #: foo.ex:17
       #: foo.ex:22
       #, elixir-autogen, elixir-format
       msgid "foo"
       msgstr ""

       #: foo.ex:24
       #, elixir-autogen, elixir-format
       msgctxt "test"
       msgid "context based message"
       msgstr ""
       """},
      {"priv/gettext/errors.pot",
       ~S"""
       msgid ""
       msgstr ""

       #: foo.ex:18
       #, elixir-autogen, elixir-format
       msgid "one error"
       msgid_plural "%{count} errors"
       msgstr[0] ""
       msgstr[1] ""
       """},
      {"messages/greetings.pot",
       ~S"""
       msgid ""
       msgstr ""

       #: foo.ex:23
       #, elixir-autogen, elixir-format
       msgid "hi"
       msgstr ""
       """}
    ]

    # No backends for the unknown app
    assert [] = Extractor.pot_files(:unknown, [])

    pot_files = Extractor.pot_files(:test_application, [])
    dumped = Enum.map(pot_files, fn {k, v} -> {k, IO.iodata_to_binary(v)} end)

    # We check that dumped strings end with the `expected` string because
    # there's the informative comment at the start of each dumped string.
    Enum.each(dumped, fn {path, contents} ->
      {^path, expected_contents} = List.keyfind(expected, path, 0)
      assert String.starts_with?(contents, "## This file is a PO Template file.")
      assert contents =~ expected_contents
    end)
  after
    Extractor.disable()
    refute Extractor.extracting?()
  end

  test "warns on conflicting backends" do
    refute Extractor.extracting?()
    Extractor.enable()
    assert Extractor.extracting?()

    code = """
    defmodule Gettext.ExtractorConflictTest.MyGettext do
      use Gettext, otp_app: :test_application
    end

    defmodule Gettext.ExtractorConflictTest.MyOtherGettext do
      use Gettext, otp_app: :test_application
    end

    defmodule FooConflict do
      import Gettext.ExtractorConflictTest.MyGettext
      require Gettext.ExtractorConflictTest.MyOtherGettext

      def bar do
        gettext("foo")
        Gettext.ExtractorConflictTest.MyOtherGettext.gettext("foo")
      end
    end
    """

    assert ExUnit.CaptureIO.capture_io(:stderr, fn ->
             Code.compile_string(code, Path.join(File.cwd!(), "foo_conflict.ex"))
             Extractor.pot_files(:test_application, [])
           end) =~
             "the Gettext backend Gettext.ExtractorConflictTest.MyGettext has the same :priv directory as Gettext.ExtractorConflictTest.MyOtherGettext"
  after
    Extractor.disable()
  end

  defp write_file(path, contents) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, contents)
  end
end
