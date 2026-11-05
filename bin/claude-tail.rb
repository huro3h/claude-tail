#!/usr/bin/env ruby
# frozen_string_literal: true

# claude-tail - Claude Code のセッションの会話を、別ターミナルで tail -f のように追いかけて
# 読みやすいテキストにする。トランスクリプト(<設定ディレクトリ>/projects/<プロジェクト名>/<セッションID>.jsonl)は
# 読むだけで、一切書き込まない。
#
# JSONL の形式は Claude Code の内部仕様で、公開ドキュメントはない。ここでの解釈は実物を観察した結果。

require 'fileutils'
require 'json'
require 'optparse'
require 'rbconfig'
require 'time'

# cron や launchd から起動されると LANG が無く、Ruby の既定エンコーディングが US-ASCII になって
# 日本語で落ちる。ロケールに依存せず UTF-8 に固定する。
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = nil
$stdout.set_encoding(Encoding::UTF_8)
$stderr.set_encoding(Encoding::UTF_8)
# ARGV は起動時にロケールの encoding で作られているので、バイト列はそのままに付け替える。
ARGV.map! { |arg| arg.dup.force_encoding(Encoding::UTF_8) }

POLL_INTERVAL = 0.5
# 2番目に新しいセッションがこの秒数以内に更新されていたら、並行して開いているとみなして警告する。
CONCURRENT_WINDOW = 10 * 60
RULE = '━━━'

class TailError < StandardError; end

module ClaudeTail
  module_function

  # Claude Code は CLAUDE_CONFIG_DIR で設定ディレクトリを移せる。未設定なら ~/.claude。
  def config_dir
    dir = ENV['CLAUDE_CONFIG_DIR']
    dir && !dir.empty? ? File.expand_path(dir) : File.join(Dir.home, '.claude')
  end

  # 作業ディレクトリの絶対パスの英数字以外をすべて '-' にしたものがプロジェクト名になる('.' も置き換わる)。
  # Claude Code 側の作業ディレクトリは実体のパス(getcwd)なので、シンボリックリンクを含むパスを
  # 渡されたとき(macOS の /var → /private/var など)は実体のパスでも探す。
  def project_dir(cwd)
    candidates = [File.expand_path(cwd)]
    candidates << File.realpath(cwd) if File.exist?(cwd)
    dirs = candidates.uniq.map { |path| File.join(config_dir, 'projects', path.gsub(/[^A-Za-z0-9]/, '-')) }
    dirs.find { |dir| File.directory?(dir) } || dirs.first
  end

  def session_id(path)
    File.basename(path, '.jsonl')
  end

  # 更新が新しい順。
  def sessions(dir)
    Dir.glob(File.join(dir, '*.jsonl')).sort_by { |path| -File.mtime(path).to_f }
  end

  # ai-title は何度か更新されるので最後の行を使う。全行をパースすると重いので、文字列で絞ってからパースする。
  def title(path)
    found = nil
    File.foreach(path, mode: 'rb') do |line|
      next unless line.include?('"ai-title"')

      record = parse(line)
      found = record['aiTitle'] if record && record['type'] == 'ai-title' && record['aiTitle']
    end
    found
  end

  def parse(line)
    record = JSON.parse(line.dup.force_encoding(Encoding::UTF_8).scrub)
    record.is_a?(Hash) ? record : nil
  rescue JSON::ParserError
    nil
  end

  def describe(path)
    t = title(path)
    t ? "#{session_id(path)} 「#{t}」" : session_id(path)
  end

  # セッションの開始時刻 = timestamp を持つ最初の行。1件も無ければファイルの更新日時。
  def started_at(path)
    File.foreach(path, mode: 'rb') do |line|
      next unless line.include?('"timestamp"')

      record = parse(line)
      time = record && local_time_of(record['timestamp'])
      return time if time
    end
    File.mtime(path)
  end

  # CLAUDE_TAIL_LOG_DIR に書き出すファイルのパス。<開始日>_<タイトル>_<IDの先頭8文字>.txt。
  # タイトルは途中で変わるので、同じセッションの既存ファイルがあれば今のタイトルの名前へ付け替えて使い続ける。
  def log_path(dir, path)
    id = session_id(path)[0, 8]
    name_title = title(path).to_s.gsub(/\s+/, '').gsub(%r{[/\\:*?"<>|[:cntrl:]]}, '-')[0, 50]
    name = [started_at(path).strftime('%Y-%m-%d'), (name_title unless name_title.empty?), id].compact.join('_')
    dest = File.join(dir, "#{name}.txt")
    existing = Dir.children(dir).find { |f| f.end_with?("_#{id}.txt") && f != File.basename(dest) }
    File.rename(File.join(dir, existing), dest) if existing && !File.exist?(dest)
    dest
  end

  # 引数(セッションID の前方一致 / .jsonl のパス / なし)から追いかけるファイルを決める。
  def resolve(arg, cwd)
    if arg && (arg.end_with?('.jsonl') || File.file?(arg))
      raise TailError, "ファイルがありません: #{arg}" unless File.file?(arg)

      warn "claude-tail: #{arg}"
      return arg
    end

    dir = project_dir(cwd)
    all = File.directory?(dir) ? sessions(dir) : []
    raise TailError, "セッションが見つかりません(#{File.expand_path(cwd)} で開いたセッションがない): #{dir}" if all.empty?

    if arg
      hits = all.select { |path| session_id(path).start_with?(arg) }
      raise TailError, "#{arg} に一致するセッションがありません(claude-tail -l で一覧)" if hits.empty?
      if hits.size > 1
        raise TailError, "#{arg} に一致するセッションが#{hits.size}件あります。もっと長く指定してください:\n" +
                         hits.map { |path| "  #{session_id(path)}" }.join("\n")
      end

      warn "claude-tail: #{describe(hits.first)}"
      return hits.first
    end

    chosen = all.first
    warn "claude-tail: #{describe(chosen)}"
    # 「最新」は同じディレクトリでセッションを並行して開いていると外れる。気づけるように知らせる。
    if all[1] && Time.now - File.mtime(all[1]) <= CONCURRENT_WINDOW
      warn "claude-tail: 警告: 直近に更新された別のセッションもあります: #{describe(all[1])}"
      warn 'claude-tail:       違うセッションなら claude-tail -l で確かめて ID を指定してください'
    end
    chosen
  end

  def list(cwd, out)
    dir = project_dir(cwd)
    all = File.directory?(dir) ? sessions(dir) : []
    raise TailError, "セッションが見つかりません: #{dir}" if all.empty?

    all.each do |path|
      out.puts [File.mtime(path).strftime('%Y-%m-%d %H:%M:%S'), session_id(path), title(path) || '-'].join('  ')
    end
  end

  # 本文に ``` が含まれていても閉じられないよう、中のいちばん長いバッククォートの並びより長いフェンスにする。
  def fence(text)
    longest = text.scan(/`+/).map(&:size).max || 0
    mark = '`' * [3, longest + 1].max
    "#{mark}\n#{text.chomp}\n#{mark}"
  end

  def tool_use_text(item)
    name = item['name'].to_s
    input = item['input'] || {}
    body = name == 'Bash' && input.is_a?(Hash) && input['command'].is_a?(String) ? input['command'] : JSON.pretty_generate(input)
    "▶ #{name}\n#{fence(body)}"
  end

  # content は文字列のことも、{type: "text", text: ...} の配列のこともある。
  def tool_result_text(item)
    content = item['content']
    body =
      case content
      when String then content
      when Array
        content.map { |c| c.is_a?(Hash) && c['type'] == 'text' ? c['text'].to_s : "[#{c.is_a?(Hash) ? c['type'] : c.class}]" }.join("\n")
      else content.to_s
      end
    label = item['is_error'] ? '◀ result (error)' : '◀ result'
    "#{label}\n#{fence(body)}"
  end

  def local_time_of(timestamp)
    Time.iso8601(timestamp).localtime
  rescue ArgumentError, TypeError
    nil
  end

  def local_time(timestamp)
    local_time_of(timestamp)&.strftime('%Y-%m-%d %H:%M:%S')
  end

  # 1行(1イベント)を表示用の文字列にする。表示しない行は nil。
  def format(record, tools:)
    type = record['type']
    return nil unless %w[user assistant].include?(type)
    return nil if record['isMeta'] || record['isSidechain']

    message = record['message']
    content = message.is_a?(Hash) ? message['content'] : nil
    kind = type

    body =
      case content
      when String then content
      when Array
        items = content.select { |item| item.is_a?(Hash) }
        # tool_result だけの user の行は人の発言ではないので、見出しを tool にして紛れないようにする。
        kind = 'tool' if type == 'user' && !items.empty? && items.all? { |item| item['type'] == 'tool_result' }
        items.filter_map do |item|
          case item['type']
          when 'text' then item['text']
          when 'tool_use' then tool_use_text(item) if tools
          when 'tool_result' then tool_result_text(item) if tools
          end
        end.join("\n\n")
      end
    return nil if body.nil? || body.strip.empty?

    heading = [RULE, kind, local_time(record['timestamp']), RULE].compact.join(' ')
    "#{heading}\n#{body.chomp}\n\n"
  end

  # tail -f 相当。読んだバイト列はバッファに溜め、改行まで揃った行だけを処理する。
  # 書きかけの行を JSON としてパースしないため(gets は末尾の改行なしの断片も1行として返す)。
  # 改行でしか切らないので、マルチバイト文字がチャンクの境目で割れても行としては揃う。
  def tail(path, outs, follow:, new_only:, tools:)
    File.open(path, 'rb') do |f|
      buf = +''.b
      skip_partial = false
      if new_only
        f.seek(0, IO::SEEK_END)
        # 末尾が書きかけの行なら、その残りが後から届く。行の途中から読まないよう次の改行まで捨てる。
        if f.pos.positive?
          f.seek(-1, IO::SEEK_END)
          skip_partial = f.read(1) != "\n"
        end
      end

      loop do
        chunk = f.read_nonblock(1 << 16, exception: false)
        if chunk.is_a?(String)
          buf << chunk
          while (i = buf.index("\n"))
            line = buf.slice!(0..i)
            if skip_partial
              skip_partial = false
              next
            end
            next if line.strip.empty?

            record = parse(line)
            text = record && format(record, tools: tools)
            next unless text

            outs.each do |out|
              out.write(text)
              out.flush
            end
          end
          next
        end
        # 止める合図は末尾まで読み切ってから見る。セッションの終了直前に書かれた発言を取りこぼさないため。
        break if !follow || stop_requested?

        sleep POLL_INTERVAL
      end
    end
  end

  # TERM を受けた(フックの SessionEnd から止められた)か、見張っている Claude Code のプロセスがいなくなった。
  def stop_requested?
    @stop || (@watch_pid && !alive?(@watch_pid))
  end

  def request_stop
    @stop = true
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  # ---- Claude Code の hooks から使う(--hook-start / --hook-end) ----
  # SessionStart で裏に追いかけるプロセスを起動し、SessionEnd で止める。
  # どのプロセスがどのセッションのものかは、状態ディレクトリの <セッションID>.pid に置く。

  def state_dir
    base = ENV['XDG_STATE_HOME']
    File.join(base && !base.empty? ? base : File.join(Dir.home, '.local', 'state'), 'claude-tail')
  end

  # フックには標準入力で JSON が渡る(session_id, transcript_path, cwd, source / reason など)。
  def read_hook_input
    input = parse($stdin.read.to_s)
    raise TailError, 'フックの入力(標準入力の JSON)が読めません' unless input

    id = input['session_id'].to_s.gsub(/[^A-Za-z0-9-]/, '')
    raise TailError, 'フックの入力に session_id がありません' if id.empty?

    [input, File.join(state_dir, "#{id}.pid")]
  end

  # pid が使い回されて別のプロセスを指している場合に止めないよう、claude-tail のプロセスかまで確かめる。
  def follower_pid(pid_file)
    pid = File.read(pid_file).to_i
    return nil unless pid.positive? && alive?(pid)

    command = IO.popen(['ps', '-o', 'command=', '-p', pid.to_s], err: File::NULL, &:read).to_s
    command.include?('claude-tail') ? pid : nil
  rescue Errno::ENOENT
    nil
  end

  # フックのコマンドはシェル経由で起動されることがあるので、シェルを飛ばして Claude Code 本体の pid まで遡る。
  # セッションの終了でフックが呼ばれずに Claude Code が落ちた(ターミナルごと閉じたなど)ときに、
  # 追いかけるプロセスが残り続けないよう、この pid を見張らせる。
  def claude_pid
    pid = Process.ppid
    5.times do
      ppid, comm = IO.popen(['ps', '-o', 'ppid=,comm=', '-p', pid.to_s], err: File::NULL, &:read).to_s.strip.split(/\s+/, 2)
      break unless comm && %w[sh bash zsh dash fish].include?(File.basename(comm).delete_prefix('-'))

      pid = ppid.to_i
    end
    pid
  end

  def hook_start(tools:)
    input, pid_file = read_hook_input
    transcript = input['transcript_path'].to_s
    raise TailError, 'フックの入力に transcript_path がありません' if transcript.empty?

    log_dir = ENV['CLAUDE_TAIL_LOG_DIR']
    raise TailError, '--hook-start には書き出し先の CLAUDE_TAIL_LOG_DIR が要ります' if log_dir.nil? || log_dir.empty?

    # resume や compact でも SessionStart は呼ばれる。同じセッションを追いかけているなら何もしない。
    return if File.exist?(pid_file) && follower_pid(pid_file)

    FileUtils.mkdir_p(state_dir)
    # 書き出しはするが、フックの標準出力は Claude への文脈になるので、追いかけるプロセスの出力は捨てる。
    # 新しいプロセスグループにして、ターミナルの Ctrl-C が届かないようにする。
    args = [RbConfig.ruby, File.realpath(__FILE__), '--wait', '--watch-pid', claude_pid.to_s]
    args << '-t' if tools
    args << transcript
    pid = Process.spawn(*args, in: File::NULL, out: File::NULL, err: [File.join(state_dir, 'hook.log'), 'a'], pgroup: true)
    Process.detach(pid)
    File.write(pid_file, pid.to_s)
  end

  def hook_end
    _input, pid_file = read_hook_input
    return unless File.exist?(pid_file)

    pid = follower_pid(pid_file)
    # TERM を受けたプロセスは、末尾まで読み切ってから自分で終わる。
    Process.kill('TERM', pid) if pid
    File.delete(pid_file)
  rescue Errno::ESRCH, Errno::ENOENT
    nil
  end

  def run(argv)
    opts = { follow: true, new_only: false, tools: false, output: nil, save: true, list: false, cwd: Dir.pwd }
    parser = OptionParser.new do |o|
      o.banner = 'Usage: claude-tail [options] [セッションIDの前方一致 | path/to/session.jsonl]'
      o.separator ''
      o.separator 'Claude Code のセッションの会話を追いかけて表示する。引数なしなら今のディレクトリの最新セッション。'
      o.separator ''
      o.on('-o', '--output FILE', '画面に流しつつファイルにも書き出す(上書き)') { |v| opts[:output] = v }
      o.on('--no-save', 'CLAUDE_TAIL_LOG_DIR が設定されていても書き出さない') { opts[:save] = false }
      o.on('-n', '--new', '既存分は飛ばし、これからの発言だけを出す') { opts[:new_only] = true }
      o.on('-t', '--tools', 'ツール呼び出しと結果も出す') { opts[:tools] = true }
      o.on('--no-follow', '今ある分を出して終了する') { opts[:follow] = false }
      o.on('-l', '--list', 'セッション一覧(更新が新しい順、タイトル付き)') { opts[:list] = true }
      o.on('-C', '--directory DIR', 'DIR で開いたセッションを対象にする') { |v| opts[:cwd] = v }
      o.on('--hook-start', 'Claude Code の SessionStart フック用。裏で記録を始める(-t も付けられる)') { opts[:hook] = :start }
      o.on('--hook-end', 'Claude Code の SessionEnd フック用。--hook-start で始めた記録を止める') { opts[:hook] = :end }
      # 以下2つは --hook-start が裏のプロセスに付けるもの。
      o.on('--wait', '(内部用)ファイルができるまで待つ') { opts[:wait] = true }
      o.on('--watch-pid PID', Integer, '(内部用)PID のプロセスがいなくなったら終わる') { |v| @watch_pid = v }
      o.on('-h', '--help', 'このヘルプ') do
        puts o
        exit 0
      end
    end
    args = parser.parse(argv)
    raise TailError, "引数が多すぎます: #{args.join(' ')}" if args.size > 1

    case opts[:hook]
    when :start then return hook_start(tools: opts[:tools])
    when :end then return hook_end
    end

    if opts[:list]
      list(opts[:cwd], $stdout)
      return
    end

    if opts[:wait]
      # SessionStart の時点ではトランスクリプトがまだ作られていないことがある(最初の発言で作られる)。
      path = args.first or raise TailError, '--wait にはファイルの指定が要ります'
      until File.file?(path)
        return if stop_requested?

        sleep POLL_INTERVAL
      end
    else
      path = resolve(args.first, opts[:cwd])
    end
    outs = [$stdout]
    file = nil
    log_dir = ENV['CLAUDE_TAIL_LOG_DIR']
    if opts[:output]
      file = File.open(opts[:output], 'w')
    elsif opts[:save] && log_dir && !log_dir.empty?
      # 環境変数で決めた既定の書き出し先。-o と違い、-n のときは前回までの記録を消さないよう追記する。
      dir = File.expand_path(log_dir)
      FileUtils.mkdir_p(dir)
      dest = log_path(dir, path)
      warn "claude-tail: 書き出し先: #{dest}"
      file = File.open(dest, opts[:new_only] ? 'a' : 'w')
    end
    outs << file if file
    begin
      tail(path, outs, follow: opts[:follow], new_only: opts[:new_only], tools: opts[:tools])
    ensure
      file&.close
    end
  rescue Errno::EPIPE
    # head などに渡して読み手が先に閉じた。正常終了扱い。
    exit 0
  rescue OptionParser::ParseError, TailError, SystemCallError => e
    warn "claude-tail: #{e.message}"
    exit 2
  end
end

if $PROGRAM_NAME == __FILE__
  Signal.trap('INT') { exit 0 }
  # TERM はすぐには終わらず、ファイルの末尾まで読み切ってから終わる(stop_requested?)。
  Signal.trap('TERM') { ClaudeTail.request_stop }
  ClaudeTail.run(ARGV)
end
