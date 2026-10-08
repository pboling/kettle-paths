# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "pathname"

RSpec.describe Kettle::Paths do
  subject(:paths) { described_class }

  # Builds a real project tree so identity comparisons have something to stat.
  def project_tree(dir, *relative_files)
    relative_files.each do |relative_file|
      full = File.join(dir, relative_file)
      FileUtils.mkdir_p(File.dirname(full))
      FileUtils.touch(full)
    end
    dir
  end

  # Creates a symlink to dir inside a second uniquely-named tmpdir. The unique
  # name and parent avoid the Errno::EEXIST collision a fixed name in the shared
  # system temp dir would cause under a parallel runner, and let mktmpdir remove
  # the link itself (via lstat, without following it into the target), so there
  # is no manual unlink that could race with or remove another run's link.
  #
  # Yields the link path, or skips when the filesystem cannot make symlinks.
  def with_symlink_to(dir)
    Dir.mktmpdir("kettle-paths-link") do |link_dir|
      link = File.join(link_dir, "ancestor")
      begin
        File.symlink(dir, link)
      rescue NotImplementedError, Errno::EACCES, Errno::EPERM
        skip "symlinks unavailable on this filesystem"
      end
      yield link
    end
  end

  it "has a version number" do
    expect(Kettle::Paths::VERSION).not_to be_nil
  end

  describe ".relative" do
    it "returns the path relative to the root" do
      Dir.mktmpdir("kettle-paths") do |dir|
        project_tree(dir, File.join("gems", "example", "spec", "example_spec.rb"))
        file = File.join(dir, "gems", "example", "spec", "example_spec.rb")

        expect(paths.relative(file, dir)).to eq("gems/example/spec/example_spec.rb")
      end
    end

    it "returns '.' when the path is the root itself" do
      Dir.mktmpdir("kettle-paths") do |dir|
        expect(paths.relative(dir, dir)).to eq(".")
      end
    end

    it "returns nil when the path is outside the root" do
      Dir.mktmpdir("kettle-paths") do |dir|
        expect(paths.relative(File.expand_path("..", dir), dir)).to be_nil
      end
    end

    # This is the property Pathname#relative_path_from gets wrong: it is purely
    # lexical, so with differing spellings it walks up past the root and returns
    # a plausible-looking escape rather than raising. Callers then hand that
    # escape to `git add` ("is outside repository at") or to a runner that
    # silently selects the wrong files. nil must stay nil, never an escape.
    it "never returns a parent-directory escape for a path outside the root" do
      Dir.mktmpdir("kettle-paths") do |root|
        Dir.mktmpdir("kettle-paths-other") do |other|
          result = paths.relative(other, root)

          expect(result).to be_nil
          expect(result.to_s).not_to include("..")
        end
      end
    end

    it "returns nil for a blank argument" do
      Dir.mktmpdir("kettle-paths") do |dir|
        expect(paths.relative(nil, dir)).to be_nil
        expect(paths.relative("", dir)).to be_nil
        expect(paths.relative(dir, nil)).to be_nil
        expect(paths.relative(dir, "")).to be_nil
      end
    end

    # Callers stat the returned path and spawn processes from that working
    # directory, so the result must keep the caller's spelling. Resolving a
    # mid-path symlink to its target would silently change which files a glob or
    # a test runner sees.
    it "preserves the caller's spelling rather than resolving symlinks" do
      Dir.mktmpdir("kettle-paths") do |dir|
        project_tree(dir, File.join("spec", "a_spec.rb"))

        with_symlink_to(dir) do |link|
          expect(paths.relative(File.join(link, "spec", "a_spec.rb"), link)).to eq("spec/a_spec.rb")
        end
      end
    end

    # Windows regression, reproduced portably. Dir.pwd / ENV["TEMP"] report 8.3
    # short names (C:/Users/RUNNER~1/...) while Dir.glob, which RSpec uses to
    # expand --pattern, reports long names (C:/Users/runneradmin/...). Both
    # spellings name the same directory, but File.realpath does NOT expand 8.3
    # names, so canonicalizing cannot reconcile them. A symlinked ancestor is the
    # portable face of the same mismatch, and File.identical? resolves it because
    # it compares by filesystem identity rather than by string.
    it "relativizes when the file and root are spelled through different ancestors" do
      Dir.mktmpdir("kettle-paths") do |dir|
        real_root = File.realpath(dir)
        project_tree(real_root, File.join("gems", "example", "spec", "example_spec.rb"))
        file = File.join(real_root, "gems", "example", "spec", "example_spec.rb")
        expected = "gems/example/spec/example_spec.rb"

        with_symlink_to(real_root) do |link|
          # root spelled via the symlink, file spelled via the real path
          expect(paths.relative(file, link)).to eq(expected)
          # and the reverse: file via the symlink, root via the real path
          expect(paths.relative(File.join(link, expected), real_root)).to eq(expected)
        end
      end
    end

    it "works when the relative path does not exist yet" do
      Dir.mktmpdir("kettle-paths") do |dir|
        expect(paths.relative(File.join(dir, "generated", "out", "file.rb"), dir))
          .to eq("generated/out/file.rb")
      end
    end
  end

  describe ".relative_from" do
    it "returns the expanded path when the file is outside the root" do
      Dir.mktmpdir("kettle-paths") do |dir|
        outside = File.expand_path("..", dir)

        expect(paths.relative_from(outside, dir)).to eq(outside)
      end
    end

    it "returns the expanded path when the file does not exist outside the root" do
      Dir.mktmpdir("kettle-paths") do |dir|
        sibling = File.join(File.expand_path("..", dir), "elsewhere.rb")

        expect(paths.relative_from(sibling, dir)).to eq(sibling)
      end
    end

    it "relativizes a missing path that is inside the root" do
      Dir.mktmpdir("kettle-paths") do |dir|
        missing = File.join(dir, "spec", "nope_spec.rb")

        expect(paths.relative_from(missing, dir)).to eq("spec/nope_spec.rb")
      end
    end

    # Uses a path relative to the real cwd (specs run from the repo root) rather
    # than Dir.chdir, which is process-wide and unsafe under a parallel runner.
    it "expands a relative file path against the current directory" do
      file = File.join("lib", "kettle", "paths.rb")
      expect(File.exist?(file)).to be(true)

      expect(paths.relative_from(file, Dir.pwd)).to eq("lib/kettle/paths.rb")
    end

    it "expands a '.' root to the current directory" do
      file = File.join("lib", "kettle", "paths.rb")
      expect(File.exist?(file)).to be(true)

      expect(paths.relative_from(file, ".")).to eq("lib/kettle/paths.rb")
    end

    it "returns '.' when the file is the root itself" do
      Dir.mktmpdir("kettle-paths") do |dir|
        expect(paths.relative_from(dir, dir)).to eq(".")
      end
    end

    it "relativizes across a symlinked ancestor" do
      Dir.mktmpdir("kettle-paths") do |dir|
        real_root = File.realpath(dir)
        project_tree(real_root, File.join("spec", "a_spec.rb"))
        expected = "spec/a_spec.rb"

        with_symlink_to(real_root) do |link|
          expect(paths.relative_from(File.join(real_root, expected), link)).to eq(expected)
          expect(paths.relative_from(File.join(link, expected), real_root)).to eq(expected)
        end
      end
    end
  end

  describe ".within?" do
    it "is false for nil or blank arguments" do
      Dir.mktmpdir("kettle-paths") do |dir|
        expect(paths.within?(nil, dir)).to be(false)
        expect(paths.within?("", dir)).to be(false)
        expect(paths.within?(dir, nil)).to be(false)
        expect(paths.within?(dir, "")).to be(false)
      end
    end

    it "is true for a file directly in the root" do
      Dir.mktmpdir("kettle-paths") do |dir|
        project_tree(dir, "a_spec.rb")

        expect(paths.within?(File.join(dir, "a_spec.rb"), dir)).to be(true)
      end
    end

    it "is true when the path is the root itself" do
      Dir.mktmpdir("kettle-paths") do |dir|
        expect(paths.within?(dir, dir)).to be(true)
      end
    end

    it "is false for a sibling directory that shares a string prefix" do
      Dir.mktmpdir("kettle-paths") do |root|
        dir = File.join(root, "project")
        sibling = File.join(root, "project-other")
        project_tree(sibling, File.join("spec", "a_spec.rb"))
        FileUtils.mkdir_p(dir)

        # A string prefix check would wrongly report this as inside "project".
        expect(paths.within?(File.join(sibling, "spec", "a_spec.rb"), dir)).to be(false)
      end
    end

    it "is true across a symlinked ancestor" do
      Dir.mktmpdir("kettle-paths") do |dir|
        real_root = File.realpath(dir)
        project_tree(real_root, File.join("spec", "a_spec.rb"))
        file = File.join(real_root, "spec", "a_spec.rb")

        with_symlink_to(real_root) do |link|
          expect(paths.within?(file, link)).to be(true)
          expect(paths.within?(File.join(link, "spec", "a_spec.rb"), real_root)).to be(true)
        end
      end
    end

    # Generated output paths have no identity yet, so containment falls back to
    # lexical component comparison. Without this the templating and release tools
    # could not ask about files they are about to write.
    it "falls back to lexical comparison when the path does not exist" do
      Dir.mktmpdir("kettle-paths") do |dir|
        expect(paths.within?(File.join(dir, "not", "yet", "written.rb"), dir)).to be(true)
        expect(paths.within?(File.join(File.expand_path("..", dir), "elsewhere.rb"), dir)).to be(false)
      end
    end

    it "honors base for relative arguments" do
      Dir.mktmpdir("kettle-paths") do |dir|
        expect(paths.within?(File.join("sub", "x.rb"), "sub", base: dir)).to be(true)
      end
    end
  end

  describe ".identical?" do
    it "is false for a blank argument rather than raising" do
      Dir.mktmpdir("kettle-paths") do |dir|
        expect(paths.identical?(nil, dir)).to be(false)
        expect(paths.identical?(dir, nil)).to be(false)
        expect(paths.identical?("", dir)).to be(false)
      end
    end

    # File.identical? behaves differently across Rubies for a path that does not
    # exist: some raise SystemCallError (ENOENT/ENOTDIR), others return false.
    # Callers pass paths that may not exist yet, so both must degrade to string
    # equality rather than raising. Stubbed here because the raising behaviour is
    # version-dependent and cannot be asserted portably.
    it "falls back to string equality when identity raises" do
      allow(File).to receive(:identical?).and_raise(Errno::ENOENT)

      expect(paths.identical?("/some/missing", "/some/missing")).to be(true)
      expect(paths.identical?("/some/missing", "/some/other")).to be(false)
    end

    it "does not raise for a path that does not exist" do
      Dir.mktmpdir("kettle-paths") do |dir|
        missing = File.join(dir, "nope")

        # Only the absence of a raise is asserted: whether a missing path yields
        # true, false or falls back to string equality is version-dependent
        # (measured on Ruby 4.0.7 File.identical? returns false rather than
        # raising). The raising branch is covered by the stubbed example above.
        expect { paths.identical?(missing, missing) }.not_to raise_error
        expect { paths.identical?(missing, File.join(dir, "other")) }.not_to raise_error
      end
    end

    it "recognizes a directory and itself through a symlink" do
      Dir.mktmpdir("kettle-paths") do |dir|
        with_symlink_to(dir) do |link|
          expect(paths.identical?(dir, link)).to be(true)
          expect(paths.identical?(dir, File.join(link, "."))).to be(true)
        end
      end
    end

    it "is false for two different directories" do
      Dir.mktmpdir("kettle-paths") do |dir|
        Dir.mktmpdir("kettle-paths-other") do |other|
          expect(paths.identical?(dir, other)).to be(false)
        end
      end
    end
  end

  describe ".same?" do
    it "is false for nil or blank arguments" do
      Dir.mktmpdir("kettle-paths") do |dir|
        expect(paths.same?(nil, dir)).to be(false)
        expect(paths.same?(dir, nil)).to be(false)
        expect(paths.same?("", "")).to be(false)
      end
    end

    it "is true for the same directory reached through a symlink" do
      Dir.mktmpdir("kettle-paths") do |dir|
        with_symlink_to(dir) do |link|
          expect(paths.same?(dir, link)).to be(true)
        end
      end
    end

    it "honors base for relative arguments" do
      Dir.mktmpdir("kettle-paths") do |dir|
        project_tree(dir, File.join("sub", "x.rb"))

        expect(paths.same?(File.join("sub", "x.rb"), File.join(dir, "sub", "x.rb"), base: dir)).to be(true)
        expect(paths.same?("sub/x.rb", "sub/y.rb", base: dir)).to be(false)
      end
    end

    it "is false for a sibling sharing a string prefix" do
      Dir.mktmpdir("kettle-paths") do |root|
        dir = File.join(root, "project")
        sibling = File.join(root, "project-other")
        FileUtils.mkdir_p(dir)
        FileUtils.mkdir_p(sibling)

        expect(paths.same?(sibling, dir)).to be(false)
      end
    end

    it "compares missing paths lexically rather than raising" do
      Dir.mktmpdir("kettle-paths") do |dir|
        expect(paths.same?(File.join(dir, "a"), File.join(dir, "a"))).to be(true)
        expect(paths.same?(File.join(dir, "a"), File.join(dir, "b"))).to be(false)
      end
    end
  end

  describe ".canonical" do
    it "returns nil for a blank path" do
      expect(paths.canonical(nil)).to be_nil
      expect(paths.canonical("")).to be_nil
    end

    it "expands a relative path against base" do
      Dir.mktmpdir("kettle-paths") do |dir|
        expect(paths.canonical("a/b.rb", base: dir)).to eq(File.join(File.realpath(dir), "a", "b.rb"))
      end
    end

    # Templating and release tooling ask about paths they are about to create, so
    # the longest existing ancestor must be resolved and the missing suffix
    # re-attached rather than bailing out.
    it "resolves the longest existing ancestor and keeps the missing suffix" do
      Dir.mktmpdir("kettle-paths") do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib"))

        expect(paths.canonical(File.join(dir, "lib", "not", "yet.rb")))
          .to eq(File.join(File.realpath(dir), "lib", "not", "yet.rb"))
      end
    end

    it "resolves a symlinked ancestor" do
      Dir.mktmpdir("kettle-paths") do |dir|
        real = File.realpath(dir)

        with_symlink_to(dir) do |link|
          expect(paths.canonical(link)).to eq(real)
        end
      end
    end
  end

  describe ".path_parts and .comparable_parts" do
    it "splits POSIX and Windows separators alike" do
      expect(paths.path_parts("a/b/c.rb")).to eq(%w[a b c.rb])
      expect(paths.path_parts("a\\b\\c.rb")).to eq(%w[a b c.rb])
      expect(paths.path_parts("/a//b/")).to eq(%w[a b])
    end

    it "treats nil as empty" do
      expect(paths.path_parts(nil)).to be_empty
      expect(paths.comparable_parts(nil)).to be_empty
    end

    it "case-folds only on Windows" do
      expected = paths.windows? ? %w[a b] : %w[A B]

      expect(paths.comparable_parts("A/B")).to eq(expected)
    end
  end

  describe ".local_path_remote?" do
    it "is true for POSIX absolute and relative local paths" do
      %w[/abs ./rel ../up .\\win ..\\win].each do |remote|
        expect(paths.local_path_remote?(remote)).to be(true), "expected #{remote.inspect} to be a local path"
      end
    end

    it "is true for a Windows drive-absolute path" do
      expect(paths.local_path_remote?("C:/Users/x")).to be(true)
      expect(paths.local_path_remote?("C:\\Users\\x")).to be(true)
    end

    it "is false for registry URLs" do
      expect(paths.local_path_remote?("https://gem.coop/")).to be(false)
      expect(paths.local_path_remote?("https://rubygems.org/")).to be(false)
      expect(paths.local_path_remote?("git://example.com/x.git")).to be(false)
    end

    it "is false for nil or blank" do
      expect(paths.local_path_remote?(nil)).to be(false)
      expect(paths.local_path_remote?("")).to be(false)
    end
  end

  describe ".glob" do
    it "normalizes backslashes so Windows-assembled patterns match" do
      Dir.mktmpdir("kettle-paths") do |dir|
        project_tree(dir, "spec/a_spec.rb", "spec/b_spec.rb")

        expect(paths.glob(dir, "spec", "*.rb")).to contain_exactly(File.join(dir, "spec", "a_spec.rb"), File.join(dir, "spec", "b_spec.rb"))
      end
    end
  end
end
