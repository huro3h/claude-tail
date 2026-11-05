#!/usr/bin/env ruby
# frozen_string_literal: true

# claude-tail - Claude Code のセッションの会話を、別ターミナルで tail -f のように追いかけて
# 読みやすいテキストにする。トランスクリプト(<設定ディレクトリ>/projects/<プロジェクト名>/<セッションID>.jsonl)は
# 読むだけで、一切書き込まない。
#
# JSONL の形式は Claude Code の内部仕様で、公開ドキュメントはない。ここでの解釈は実物を観察した結果。

require 'json'
require 'optparse'
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

  def local_time(timestamp)
    Time.iso8601(timestamp).localtime.strftime('%Y-%m-%d %H:%M:%S')
  rescue ArgumentError, TypeError
    nil
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
        break unless follow

        sleep POLL_INTERVAL
      end
    end
  end

  def run(argv)
    opts = { follow: true, new_only: false, tools: false, output: nil, list: false, cwd: Dir.pwd }
    parser = OptionParser.new do |o|
      o.banner = 'Usage: claude-tail [options] [セッションIDの前方一致 | path/to/session.jsonl]'
      o.separator ''
      o.separator 'Claude Code のセッションの会話を追いかけて表示する。引数なしなら今のディレクトリの最新セッション。'
      o.separator ''
      o.on('-o', '--output FILE', '画面に流しつつファイルにも書き出す(上書き)') { |v| opts[:output] = v }
      o.on('-n', '--new', '既存分は飛ばし、これからの発言だけを出す') { opts[:new_only] = true }
      o.on('-t', '--tools', 'ツール呼び出しと結果も出す') { opts[:tools] = true }
      o.on('--no-follow', '今ある分を出して終了する') { opts[:follow] = false }
      o.on('-l', '--list', 'セッション一覧(更新が新しい順、タイトル付き)') { opts[:list] = true }
      o.on('-C', '--directory DIR', 'DIR で開いたセッションを対象にする') { |v| opts[:cwd] = v }
      o.on('-h', '--help', 'このヘルプ') do
        puts o
        exit 0
      end
    end
    args = parser.parse(argv)
    raise TailError, "引数が多すぎます: #{args.join(' ')}" if args.size > 1

    if opts[:list]
      list(opts[:cwd], $stdout)
      return
    end

    path = resolve(args.first, opts[:cwd])
    outs = [$stdout]
    file = nil
    if opts[:output]
      file = File.open(opts[:output], 'w')
      outs << file
    end
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
  Signal.trap('TERM') { exit 0 }
  ClaudeTail.run(ARGV)
end
