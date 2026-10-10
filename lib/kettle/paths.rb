# frozen_string_literal: true

require "pathname"
require "version_gem"
require_relative "paths/version"

module Kettle
  # Filesystem path comparison by identity rather than by spelling.
  #
  # == Why string comparison of paths is not safe
  #
  # A path string is a *name*, not an identity. One directory can have several
  # valid names, and two names can reach the same code from different APIs
  # within one process. Two cases bite these tools on every platform:
  #
  # 1. A symlinked ancestor. On Fedora Silverblue/Aurora +/home/x+ is a symlink
  #    to +/var/home/x+, so +Dir.pwd+ can report one form while a path built
  #    from an ENV var, a stored fixture, a TMPDIR, or
  #    +git rev-parse --show-toplevel+ reports the other.
  #
  # 2. Windows 8.3 short names. Measured on a GitHub Actions windows-latest
  #    runner:
  #
  #      Dir.pwd         => "C:/Users/RUNNER~1/AppData/Local/Temp/turbo-tests2-..."
  #      ENV["TEMP"]     => "C:\\Users\\RUNNER~1\\AppData\\Local\\Temp"
  #      Dir.glob result => "C:/Users/runneradmin/AppData/Local/Temp/turbo-tests2-..."
  #
  #    +RUNNER~1+ is the 8.3 short name and +runneradmin+ the long name of the
  #    same directory. +Dir.pwd+ and the environment report the short form while
  #    +Dir.glob+ — which RSpec uses to expand +--pattern+ — reports the long
  #    form. Both are correct and they are never equal as strings.
  #
  # The concrete damage: +Pathname#relative_path_from+ is purely lexical, so
  # with differing spellings it walks all the way up and back down and returns a
  # plausible-looking escape such as
  # +"../../../../../runneradmin/AppData/Local/Temp/..."+. It does not raise, so
  # a +rescue ArgumentError+ cannot catch it. Those escapes then reach
  # +git add+, which fails with "is outside repository at", or a test runner
  # that silently selects the wrong files.
  #
  # == The approach that works
  #
  # +File.identical?+ asks the filesystem whether two names denote one object —
  # by inode on Unix and by file index on Windows. It is spelling-agnostic,
  # which is exactly the property needed. So containment and relativization here
  # ascend the candidate path asking the filesystem "is this the root?", and
  # re-join basenames on the way back down.
  #
  # Lexical component comparison is kept only as a fallback for paths that do
  # not exist yet, which have no identity to ask about. That is what keeps the
  # comparison useful for generated output paths.
  #
  # == Approaches that do NOT work, and why
  #
  # All four were tried against the real failing environments and all failed;
  # recorded so the sequence is not repeated.
  #
  # 1. String prefix (+expanded.start_with?("#{root}/")+): never matches when
  #    the two spellings differ, so absolute temp paths leak through to
  #    consumers that then stat them. It also wrongly reports "project-other"
  #    as inside "project".
  #
  # 2. Canonicalize with +File.realpath+, then compare: WRONG PREMISE —
  #    +File.realpath+ does NOT expand Windows 8.3 short names. Measured on the
  #    runner, realpath of the short path returns the short path unchanged, so
  #    canonicalization cannot reconcile the two spellings at all. It also
  #    resolves symlinks, which adds a second failure mode: root and file may
  #    legitimately traverse different symlink chains to one directory, and
  #    canonicalizing only one side makes them diverge.
  #
  # 3. Component-wise comparison of canonicalized parts: same false premise as
  #    #2, so +RUNNER~1+ never equals +runneradmin+ under any case folding. It
  #    also relied on +File::ALT_SEPARATOR+, which measured as +""+ (empty
  #    string, not nil) on that runner, making the separator-normalizing +tr+ a
  #    silent no-op. Do not trust ALT_SEPARATOR to be present.
  #
  # 4. +Pathname#relative_path_from+: purely lexical, as described above.
  #
  # == How the Windows case was finally diagnosed
  #
  # It only reproduced on the Windows CI runner, and the runner's output was
  # swallowed: the discovery specs invoke a subprocess whose stderr surfaces
  # only when a status check fails, and the assertion that failed was a JSON
  # comparison. Four blind fixes failed in a row. What resolved it was a
  # temporary, Windows-guarded spec (+if: Gem.win_platform?+) that deliberately
  # failed with the diagnostic JSON embedded in the expectation message, so the
  # runner's real path forms printed into the CI log. Guarding it kept the other
  # checks green while one job reported the data; that spec was then deleted and
  # its findings became this documentation plus the specs in this gem.
  #
  # Lesson: when a bug is environment-specific and the environment is not
  # available locally, spend the iteration on instrumenting the real environment
  # rather than on another hypothesized fix.
  #
  # == Dependency-free by design
  #
  # No runtime dependencies and MIT licensed, so it can be shared by both MIT
  # and AGPL tooling without license friction. Keep it that way.
  #
  # The Ruby floor is 2.4.0 to match its consumers (kettle-dev, kettle-family and
  # turbo_tests2 all declare ">= 2.4.0"), so this file avoids +filter_map+
  # (2.7+), multi-argument +String#start_with?+ (2.5+), +Hash#to_h+ with a block
  # (2.6+) and endless method definitions.
  module Paths
    # Raised for programmer error only. Path operations here return nil or false
    # rather than raising, because a missing or unreadable path is a normal
    # condition in these tools.
    class Error < StandardError; end

    module_function

    LOCAL_REMOTE_PREFIXES = ["/", "./", "../", ".\\", "..\\"].freeze

    # Expands +path+ and resolves its longest existing ancestor, re-attaching
    # any non-existent suffix. Keeps comparisons useful for generated paths that
    # do not exist yet, which is common in templating and release tooling.
    #
    # NOTE: this does NOT make differently spelled paths comparable as strings —
    # see the class documentation on +File.realpath+ and 8.3 short names. Use
    # {same?}, {within?} or {relative} to compare, never string equality on the
    # result of this method.
    #
    # @param path [String, Pathname, nil]
    # @param base [String, nil] directory to expand a relative +path+ against
    # @return [String, nil] the expanded path, or the plain expansion when the
    #   real path cannot be resolved; nil when +path+ is blank
    def canonical(path, base: nil)
      return nil if blank?(path)

      expanded = File.expand_path(path.to_s, base)
      existing = expanded
      suffix = []
      until File.exist?(existing) || File.symlink?(existing)
        parent = File.dirname(existing)
        return expanded if parent == existing

        suffix.unshift(File.basename(existing))
        existing = parent
      end

      suffix.reduce(File.realpath(existing)) { |resolved, component| File.join(resolved, component) }
    rescue Errno::EACCES, Errno::ENOENT
      expanded
    end

    # True when +left+ and +right+ name the same filesystem object, compared by
    # identity rather than by spelling.
    #
    # @param left [String, Pathname, nil]
    # @param right [String, Pathname, nil]
    # @param base [String, nil] directory to expand relative arguments against
    # @return [Boolean] false when either argument is blank
    def same?(left, right, base: nil)
      return false if blank?(left) || blank?(right)

      left_path = canonical(left, base: base)
      right_path = canonical(right, base: base)
      return false if blank?(left_path) || blank?(right_path)
      return true if left_path == right_path

      identical?(left_path, right_path) || comparable_parts(left_path) == comparable_parts(right_path)
    rescue Errno::EACCES, Errno::ENOENT, Errno::ENOTDIR, NotImplementedError
      comparable_parts(left_path || left.to_s) == comparable_parts(right_path || right.to_s)
    end

    # Filesystem-identity comparison that tolerates a missing path.
    #
    # +File.identical?+ is not consistent across Rubies here: some raise
    # +SystemCallError+ for a path that does not exist, while others (measured on
    # Ruby 4.0.7) return false. Both are handled, because callers pass paths that
    # may not exist yet — generated output, a lockfile entry for a file about to
    # be written.
    #
    # The fallback is string equality, which is the correct answer when neither
    # side is a symlink or an 8.3 short name. Rescues +SystemCallError+ rather
    # than +Errno::ENOENT+ alone, because ENOTDIR, ELOOP and EACCES all mean
    # "identity unknown" and the string fallback is the safest answer in each
    # case.
    #
    # @param left [String, Pathname, nil]
    # @param right [String, Pathname, nil]
    # @return [Boolean]
    def identical?(left, right)
      return false if blank?(left) || blank?(right)

      left_s = left.to_s
      right_s = right.to_s
      File.identical?(left_s, right_s)
    rescue SystemCallError
      left_s == right_s
    end

    # True when +path+ is +root+ itself or lives inside it, compared by
    # filesystem identity.
    #
    # Unlike a string prefix test this does not treat a sibling directory that
    # merely shares a prefix ("project-other" vs "project") as being inside
    # "project". Unlike lexical component comparison it survives a symlinked
    # ancestor and Windows 8.3 short names.
    #
    # When identity cannot be established, because one side does not exist, this
    # falls back to lexical component comparison. That is what keeps it usable
    # for generated output paths that have not been written yet.
    #
    # @param path [String, Pathname, nil]
    # @param root [String, Pathname, nil]
    # @param base [String, nil]
    # @return [Boolean] false when either argument is blank
    def within?(path, root, base: nil)
      return false if blank?(path) || blank?(root)

      candidate = File.expand_path(path.to_s, base)
      boundary = File.expand_path(root.to_s, base)
      return true if identical?(candidate, boundary)

      !relative_parts(candidate, boundary).nil? || lexical_within?(candidate, boundary)
    rescue Errno::EACCES, Errno::ENOENT, Errno::ENOTDIR
      false
    end

    # The path of +path+ relative to +root+, computed by ascending +path+ and
    # asking the filesystem at each level whether that ancestor is +root+.
    #
    # Returns nil when +root+ is not an ancestor of +path+. Callers must not
    # substitute a lexical result for that nil: +Pathname#relative_path_from+
    # returns a plausible but wrong +../../..+ escape in exactly that case, which
    # is worse than nil because it silently selects the wrong files or fails
    # later inside +git add+.
    #
    # The returned string is built from +path+'s own spelling, which is what
    # callers need when the result is stat'd or handed to a process spawned from
    # this working directory. For that reason the path is expanded WITHOUT
    # +File.realpath+: a mid-path symlink must not be silently rewritten to its
    # target, because that changes which files a glob or a test runner sees.
    # Identity comparison via {identical?} already reconciles differing ancestor
    # spellings, so realpath buys nothing here and costs the caller's spelling.
    # See the class documentation on +File.realpath+.
    #
    # @param path [String, Pathname]
    # @param root [String, Pathname]
    # @return [String, nil] relative path using forward slashes, "." when the two
    #   name the same directory, or nil when +root+ is not an ancestor
    def relative(path, root)
      return nil if blank?(path) || blank?(root)

      candidate = File.expand_path(path.to_s)
      boundary = File.expand_path(root.to_s)
      return "." if identical?(candidate, boundary)

      relative_parts(candidate, boundary)
    end

    # {relative}, falling back to the expanded +path+ when +root+ is not an
    # ancestor, i.e. when there is nothing to strip. This is the shape spec
    # discovery needs: it passes through paths outside the configuration root
    # untouched rather than producing a wrong relative path.
    #
    # @param path [String, Pathname]
    # @param root [String, Pathname]
    # @return [String] relative path, "." for the same directory, or the expanded
    #   +path+ when it is not inside +root+
    def relative_from(path, root)
      expanded = File.expand_path(path.to_s)
      relative(expanded, root) || expanded
    end

    # Dir.glob with forward-slash normalization, so patterns assembled from
    # Windows paths still match.
    #
    # @param parts [Array<String>] joined with +File::SEPARATOR+ before globbing
    # @return [Array<String>]
    def glob(*parts)
      # Windows 8.3 short names (RUNNER~1) hide that two spellings are one
      # file, and File.expand_path does NOT resolve them: the base may stay
      # short-named while Dir.glob results come back long-named (or vice
      # versa). Compare both sides in expanded space to compute the relative
      # path, then re-prefix with the caller's original spelling, so results
      # spell the base exactly as the caller did and comparisons against
      # TMPDIR-derived expectations are spelling-independent.
      pattern = File.join(*parts).tr("\\", "/")
      original_base = pattern.split("/")[0..-2].join("/")
      original_base = original_base.empty? ? "." : original_base
      expanded_base = File.expand_path(original_base)
      base_prefix = "#{expanded_base}/"
      results = Dir.glob([pattern, File.join(expanded_base, File.basename(pattern))].uniq)
      results.map do |result|
        expanded_result = File.expand_path(result)
        relative = expanded_result.start_with?(base_prefix) ? expanded_result.delete_prefix(base_prefix) : File.basename(result)
        File.join(original_base, relative)
      end
    end

    # True when a bundler/lockfile "remote:" value denotes a local path rather
    # than a registry URL.
    #
    # @param remote [String, nil]
    # @return [Boolean]
    def local_path_remote?(remote)
      text = remote.to_s
      return false if text.empty?

      # Windows drive-absolute: "C:/x" or "C:\x"
      third_char = text[2].to_s
      drive_absolute = text.length >= 3 && text[1] == ":" && (third_char == "/" || third_char == "\\")
      drive_absolute ||
        LOCAL_REMOTE_PREFIXES.any? { |prefix| text.start_with?(prefix) } ||
        absolute_pathname?(text)
    end

    # Splits a path into its components, normalizing backslashes so Windows and
    # POSIX paths compare alike.
    #
    # @param path [String, Pathname, nil]
    # @return [Array<String>]
    def path_parts(path)
      path.to_s.tr("\\", "/").split("/").reject(&:empty?)
    end

    # {path_parts}, case-folded on Windows where the filesystem is
    # case-insensitive.
    #
    # @param path [String, Pathname, nil]
    # @return [Array<String>]
    def comparable_parts(path)
      parts = path_parts(path)
      windows? ? parts.map(&:downcase) : parts
    end

    # @api private
    def windows?
      Gem.win_platform?
    end

    # @api private
    def blank?(value)
      value.nil? || value.to_s.empty?
    end

    # @api private
    def absolute_pathname?(text)
      Pathname.new(text).absolute?
    rescue
      false
    end

    # Lexical containment, used only when identity cannot be established because
    # one side does not exist. Component-wise rather than a string prefix, so a
    # sibling sharing a prefix is not reported as contained.
    #
    # @api private
    def lexical_within?(candidate, boundary)
      candidate_parts = comparable_parts(candidate)
      boundary_parts = comparable_parts(boundary)
      boundary_length = boundary_parts.length
      return false if candidate_parts.length < boundary_length

      candidate_parts[0, boundary_length] == boundary_parts
    end

    # Ascend from +candidate+ asking the filesystem whether each ancestor is
    # +boundary+, re-joining basenames on the way back down.
    #
    # Recursion is avoided in favour of a loop: +File.dirname+ of the filesystem
    # root returns itself ("C:/" or "/"), so the +parent == current+ check ends
    # every walk without needing a depth constant. Depth is bounded by path
    # length and the cost is one stat pair per level.
    #
    # Both arguments are expected to be canonicalized already, by the public
    # entry points, so the loop compares with {identical?} rather than paying
    # for a fresh {canonical} per level.
    #
    # @return [String, nil] relative path, "." for the same directory, or nil
    #   when the boundary was never reached
    # @api private
    def relative_parts(candidate, boundary)
      directory = File.directory?(candidate)
      current = directory ? candidate : File.dirname(candidate)
      parts = directory ? [] : [File.basename(candidate)]

      until identical?(current, boundary)
        parent = File.dirname(current)
        return nil if parent == current

        parts.unshift(File.basename(current))
        current = parent
      end

      return "." if parts.empty?

      File.join(*parts).tr("\\", "/")
    end
  end
end

Kettle::Paths::Version.class_eval do
  extend VersionGem::Basic
end
