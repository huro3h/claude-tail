# frozen_string_literal: true

# 実行: ruby test/claude_tail_test.rb
# CLAUDE_CONFIG_DIR を一時ディレクトリに向けて、本物の ~/.claude には触れずに CLI を外から叩く。

require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'open3'
require 'timeout'
require 'tmpdir'

class ClaudeTailTest < Minitest::Test
  BIN = File.expand_path('../bin/claude-tail.rb', __dir__)

  def setup
    # Claude Code は実体のパスでプロジェクト名を作るので、それに合わせる(macOS の一時ディレクトリは /var → /private/var)。
    @tmp = File.realpath(Dir.mktmpdir('claude-tail-test'))
    @config = File.join(@tmp, 'config')
    @work = File.join(@tmp, 'my.app')
    FileUtils.mkdir_p(@work)
    # 手元のシェルで CLAUDE_TAIL_LOG_DIR を設定していても、テストでは書き出さない。
    @env = { 'CLAUDE_CONFIG_DIR' => @config, 'TZ' => 'UTC', 'CLAUDE_TAIL_LOG_DIR' => nil }
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def project_dir
    dir = File.join(@config, 'projects', File.expand_path(@work).gsub(/[^A-Za-z0-9]/, '-'))
    FileUtils.mkdir_p(dir)
    dir
  end

  def write_session(id, records, mtime: nil)
    path = File.join(project_dir, "#{id}.jsonl")
    File.write(path, records.map { |r| JSON.generate(r) + "\n" }.join)
    File.utime(mtime, mtime, path) if mtime
    path
  end

  def run_cli(*args, env: @env)
    Open3.capture3(env, 'ruby', BIN, *args, chdir: @work)
  end

  def user(text, ts = '2026-01-01T00:00:00Z', **extra)
    { 'type' => 'user', 'timestamp' => ts, 'message' => { 'content' => text } }.merge(extra.transform_keys(&:to_s))
  end

  def assistant(items, ts = '2026-01-01T00:00:01Z', **extra)
    { 'type' => 'assistant', 'timestamp' => ts, 'message' => { 'content' => items } }.merge(extra.transform_keys(&:to_s))
  end

  def sample
    [
      { 'type' => 'ai-title', 'aiTitle' => '古いタイトル' },
      user('こんにちは'),
      assistant([{ 'type' => 'thinking', 'thinking' => '考え中' }]),
      assistant([{ 'type' => 'text', 'text' => "## 見出し\n本文です" }]),
      assistant([{ 'type' => 'tool_use', 'id' => 't1', 'name' => 'Bash', 'input' => { 'command' => 'echo hi' } }]),
      { 'type' => 'user', 'timestamp' => '2026-01-01T00:00:02Z',
        'message' => { 'content' => [{ 'type' => 'tool_result', 'tool_use_id' => 't1',
                                       'content' => [{ 'type' => 'text', 'text' => "hi\n```inner```" }] }] } },
      assistant([{ 'type' => 'tool_use', 'id' => 't2', 'name' => 'Read', 'input' => { 'file_path' => 'a.txt' } }]),
      { 'type' => 'user', 'isMeta' => true, 'message' => { 'content' => [{ 'type' => 'text', 'text' => 'スキル本文' }] } },
      user('サブエージェントへの指示', isSidechain: true),
      { 'type' => 'permission-mode', 'permissionMode' => 'default' },
      '{"type":"user","message":{"content":"壊れた行',
      { 'type' => 'ai-title', 'aiTitle' => '新しいタイトル' }
    ]
  end

  def write_sample(id = '11111111-aaaa')
    path = File.join(project_dir, "#{id}.jsonl")
    File.write(path, sample.map { |r| (r.is_a?(String) ? r : JSON.generate(r)) + "\n" }.join)
    path
  end

  def test_no_follow_shows_conversation_only
    write_sample
    out, err, status = run_cli('--no-follow')
    assert_equal 0, status.exitstatus, err
    assert_equal <<~TEXT, out
      ━━━ user 2026-01-01 00:00:00 ━━━
      こんにちは

      ━━━ assistant 2026-01-01 00:00:01 ━━━
      ## 見出し
      本文です

    TEXT
    assert_includes err, '11111111-aaaa 「新しいタイトル」'
  end

  def test_tools_option
    write_sample
    out, _err, status = run_cli('--no-follow', '-t')
    assert_equal 0, status.exitstatus
    assert_includes out, "▶ Bash\n```\necho hi\n```"
    assert_includes out, "━━━ tool 2026-01-01 00:00:02 ━━━\n◀ result\n````\nhi\n```inner```\n````"
    assert_includes out, "▶ Read\n```\n{\n  \"file_path\": \"a.txt\"\n}\n```"
    refute_includes out, 'スキル本文'
    refute_includes out, 'サブエージェント'
    refute_includes out, '考え中'
  end

  def test_output_file
    write_sample
    dest = File.join(@tmp, 'out.txt')
    File.write(dest, '古い中身')
    out, _err, status = run_cli('--no-follow', '-o', dest)
    assert_equal 0, status.exitstatus
    assert_equal out, File.read(dest)
  end

  def test_list_and_prefix
    write_session('aaaa1111', [{ 'type' => 'ai-title', 'aiTitle' => 'A' }, user('A の発言')], mtime: Time.now - 3600)
    write_session('aaaa2222', [user('B の発言')], mtime: Time.now - 60)

    out, _err, status = run_cli('-l')
    assert_equal 0, status.exitstatus
    lines = out.lines
    assert_match(/aaaa2222  -$/, lines[0])
    assert_match(/aaaa1111  A$/, lines[1])

    out, _err, status = run_cli('aaaa1', '--no-follow')
    assert_equal 0, status.exitstatus
    assert_includes out, 'A の発言'

    _out, err, status = run_cli('aaaa', '--no-follow')
    assert_equal 2, status.exitstatus
    assert_includes err, '2件'

    _out, _err, status = run_cli('zzzz', '--no-follow')
    assert_equal 2, status.exitstatus
  end

  def test_warns_concurrent_session
    write_session('old', [user('x')], mtime: Time.now - 120)
    write_session('new', [user('y')])
    _out, err, = run_cli('--no-follow')
    assert_includes err, '警告'

    write_session('old', [user('x')], mtime: Time.now - 3600)
    _out, err, = run_cli('--no-follow')
    refute_includes err, '警告'
  end

  def test_directory_option_and_missing_project
    write_sample
    other = File.join(@tmp, 'other')
    FileUtils.mkdir_p(other)
    out, _err, status = Open3.capture3(@env, 'ruby', BIN, '--no-follow', '-C', @work, chdir: other)
    assert_equal 0, status.exitstatus
    assert_includes out, 'こんにちは'

    # シンボリックリンク経由で指定しても、実体のパスのプロジェクトが見つかる。
    link = File.join(@tmp, 'link')
    File.symlink(@work, link)
    out, _err, status = Open3.capture3(@env, 'ruby', BIN, '--no-follow', '-C', link, chdir: other)
    assert_equal 0, status.exitstatus
    assert_includes out, 'こんにちは'

    _out, err, status = Open3.capture3(@env, 'ruby', BIN, '--no-follow', chdir: other)
    assert_equal 2, status.exitstatus
    assert_includes err, 'セッションが見つかりません'
  end

  def test_log_dir
    path = write_sample('11111111-aaaa')
    logs = File.join(@tmp, 'logs')
    env = @env.merge('CLAUDE_TAIL_LOG_DIR' => logs)

    out, err, status = run_cli('--no-follow', env: env)
    assert_equal 0, status.exitstatus, err
    dest = File.join(logs, '2026-01-01_新しいタイトル_11111111.txt')
    assert_includes err, "書き出し先: #{dest}"
    assert_equal out, File.read(dest)

    # タイトルが変わったら、同じセッションのファイルを新しい名前へ付け替える。
    File.write(path, JSON.generate({ 'type' => 'ai-title', 'aiTitle' => 'a/b c' }) + "\n", mode: 'a')
    _out, _err, status = run_cli('--no-follow', env: env)
    assert_equal 0, status.exitstatus
    assert_equal ['2026-01-01_a-bc_11111111.txt'], Dir.children(logs)

    # -n は前回までの記録を消さずに追記する。
    _out, _err, status = run_cli('--no-follow', '-n', env: env)
    assert_equal 0, status.exitstatus
    assert_includes File.read(File.join(logs, '2026-01-01_a-bc_11111111.txt')), 'こんにちは'

    # --no-save と -o では既定の書き出し先を使わない。
    FileUtils.rm_rf(logs)
    run_cli('--no-follow', '--no-save', env: env)
    other = File.join(@tmp, 'other.txt')
    run_cli('--no-follow', '-o', other, env: env)
    refute File.exist?(logs)
    assert File.exist?(other)
  end

  def test_direct_path_without_project
    path = File.join(@tmp, 'direct.jsonl')
    File.write(path, JSON.generate(user('直接')) + "\n")
    out, _err, status = run_cli(path, '--no-follow')
    assert_equal 0, status.exitstatus
    assert_includes out, '直接'
  end

  def test_without_locale
    write_sample
    env = @env.merge('LANG' => nil, 'LC_ALL' => nil, 'LC_CTYPE' => nil)
    out, err, status = run_cli('--no-follow', env: env)
    assert_equal 0, status.exitstatus, err
    assert_includes out, 'こんにちは'
  end

  # 書きかけの行は改行が届くまで出さない。Ctrl-C で終了コード 0。
  def test_follow_partial_line_and_interrupt
    path = File.join(@tmp, 'follow.jsonl')
    File.write(path, '')
    Open3.popen3(@env, 'ruby', BIN, path) do |stdin, stdout, _stderr, wait|
      stdin.close
      File.write(path, JSON.generate(user('hello')) + "\n", mode: 'a')
      assert_includes read_until(stdout, 'hello'), 'hello'

      first, rest = JSON.generate(assistant([{ 'type' => 'text', 'text' => '前半と後半' }])).split('と', 2)
      File.write(path, first, mode: 'a')
      sleep 1.2
      assert_empty stdout.read_nonblock(4096, exception: false).then { |s| s.is_a?(String) ? s : '' }

      File.write(path, "と#{rest}\n", mode: 'a')
      assert_includes read_until(stdout, '前半と後半'), '前半と後半'

      Process.kill('INT', wait.pid)
      assert_equal 0, wait.value.exitstatus
    end
  end

  def test_new_only_skips_existing_and_partial_tail
    path = File.join(@tmp, 'new.jsonl')
    File.write(path, JSON.generate(user('既存')) + "\n" + '{"type":"user","message":{"cont')
    Open3.popen3(@env, 'ruby', BIN, '-n', path) do |stdin, stdout, _stderr, wait|
      stdin.close
      sleep 0.8
      File.write(path, "ent\":\"書きかけの続き\"}}\n" + JSON.generate(user('新しい発言')) + "\n", mode: 'a')
      out = read_until(stdout, '新しい発言')
      refute_includes out, '既存'
      refute_includes out, '書きかけの続き'
      Process.kill('INT', wait.pid)
      wait.value
    end
  end

  private

  def read_until(io, needle, timeout: 5)
    buf = +''
    Timeout.timeout(timeout) do
      buf << io.readpartial(4096).force_encoding(Encoding::UTF_8) until buf.include?(needle)
    end
    buf
  end
end
