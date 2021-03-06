#!/usr/bin/ruby
# vim: set fileencoding=utf-8 :

require 'serialport'
require 'json'
require 'pathname'
require 'sinatra/base'
require 'sinatra/reloader'
require 'time'


#
# シリアル通信で IrMagician をコントロールする
#
class IrMagician
  # @param path [String] デバイスへのパス (/dev/ttyACM0 など)
  def initialize (path)
    @path = path
    reopen
  end

  # 再接続
  def reopen
    @serial_port = SerialPort.new(@path, 9600, 8, 1, 0)
    @serial_port.read_timeout = 5000
    skip_banner
  end

  # 自動的にリトライ付きで実行する
  #
  # @param block [Proc] 実行するブロック
  def automatic_retry (&block)
    begin
      block.call
    rescue
      sleep(1)
      reopen
      block.call
    end
  end

  # キャプチャを開始する
  #
  # このメソッド呼び出し直後に、IrMagician に向けてリモコンでキャプチャさせたいボタンを押すなどする
  # キャプチャに成功すると、IrMagician 内にリモコンのデータが記録される
  #
  # @return [Array] [成否, キャプチャサイズ/エラーメッセージ] な 2要素の配列
  def capture ()
    @serial_port.puts('c')
    response = @serial_port.gets
    if m = response.match(/\.{3} (\d+)/)
      [true, m[1].to_i]
    else
      [false, response]
    end
  end

  # キャプチャしている内容を Hash で返す
  #
  # このデータは、record メソッドなどで仕様できる
  #
  # @return [Hash] キャプチャ内容
  def dump ()
    @serial_port.puts('i,6')
    scale = @serial_port.gets.to_i(10)

    @serial_port.puts('i,1')
    size = @serial_port.gets.to_i(16)

    blocks = size / 64 + 1

    data =
      blocks.times.map do
        |block|
        @serial_port.puts('b,%d' % block)
        block_size = (block == blocks - 1) ? size % 64 : 64
        block_size.times.map do
          |offset|
          @serial_port.puts('d,%d' % offset)
          @serial_port.read(2).to_i(16).tap {
            @serial_port.read(1)
          }
        end
      end

    {'scale' => scale, 'data' => data}
  end

  # IrMagician が現在記録しているデータで、発信する
  #
  # 事前に capture か record している必要がある
  def play ()
    @serial_port.puts('p')
    @serial_port.gets
  end

  # 発信内容を記録する
  #
  # capture -> dump で得られたデータをそのまま用いれば良い
  #
  # @param scale [Fixnum]
  # @param blocks [Array] 二次元配列
  def record (scale, blocks)
    size = blocks.map(&:size).inject(&:+)

    @serial_port.puts('n,%d' % size)
    @serial_port.puts('k,%d' % scale)
    @serial_port.gets

    blocks.each_with_index do
      |block, i|
      @serial_port.puts('b,%d' % i)
      block.each_with_index do
        |byte, j|
        @serial_port.puts('w,%d,%d' % [j, byte])
      end
    end
  end

  # IrMagician をリセットする
  #
  # どういう効果だったか忘れた
  #
  # @param n [Fixnum] 0 か 1 のはず
  def reset (n = 0)
    @serial_port.puts('r,%d' % n)
    @serial_port.gets.chomp == 'OK'
  end

  private
  def skip_banner
    before = @serial_port.read_timeout
    @serial_port.read_timeout = -1 # no wait
    @serial_port.gets
    @serial_port.read_timeout = before
  end
end


class Profiles < Array
  IR_MAGI_DIR = Pathname(ENV['HOME']) + '.irmagi'

  def initialize
    super
    update
  end

  def update
    clear
    IR_MAGI_DIR.entries.select {|it| (IR_MAGI_DIR + it).file? } .sort.map {|it| it.sub_ext('') }.each { |it|
      self << it
    }
  end

  def read(name)
    JSON.parse(File.read(to_path(name)))
  end

  def write(name, json_object)
    content = JSON.pretty_generate(json_object)
    file = to_path(name)
    file.parent.mkpath
    File.write(file, content)
    file
  end

  def to_path (name)
    IR_MAGI_DIR + "#{name}.json"
  end
end


class HistoryEntry < Struct.new(:time, :path, :host)
end


class Server < Sinatra::Base
  configure :development do
    register Sinatra::Reloader
  end

  enable :sessions

  before do
    path = request.path_info
    return if %W[/ /history].include?(path)
    host = request.env['HTTP_X_FORWARDED_FOR']|| request.host
    settings.history << HistoryEntry.new(Time.now, path, host)
  end

  get '/' do
    @message = session[:message]
    session[:message] = nil

    erb(wrap(<<-EOT))
  <% if @message %>
    <h1>Result</h1>
    <%= @message %>
  <% end %>
  <h1>Play</h1>
  <ol>
    <% settings.app.profiles.each do|it| %>
      <li><a href="./play/<%= it.to_s %>"><%= it.to_s %></a></li>
    <% end %>
  </ol>
  <h1>Capture</h1>
  <form action="./capture" method="POST">
    <label>Name: </label><input type="text" name="name" />
    <input type="submit" value="Capture" />
  </form>
  <h1>Other</h1>
  <ol>
    <li><a href="./history">History</a></li>
  </ol>
EOT
  end

  get '/play/:profile' do
    profile = params[:profile]
    settings.app.play(profile)
    result("OK: #{profile}")
  end

  post '/capture' do
    name = params[:name]
    if name and !name.empty?
      ok, code = settings.app.capture(name)
      if ok
        result("Captured: #{name}")
      else
        result("Failed: #{code}")
      end
    else
      result("Failed: please input name.")
    end
  end

  get '/history' do
    erb(wrap(<<-EOT))
  <h1>History</h1>
  <dl>
    <% settings.history.reverse.each do |entry| %>
      <dt><%= entry.path %></dt>
      <dd><%= entry.time.strftime('%Y%m%d %H:%M:%S') %> <%= entry.host %></dd>
    <% end %>
  </dl>
  <a href="./">Top</a>
EOT
  end

  get '/api/help' do
    return <<-EOT
/api/profiles
/api/profiles/:profiles/play
EOT
  end

  get '/api/profiles' do
    settings.app.profiles.join("\n") + "\n"
  end

  get '/api/:profiles/play' do
    profiles = params[:profiles]
    profiles.split(/,/).each do |profile|
      settings.app.play(profile)
      sleep 2
    end
    "OK: #{profiles}"
  end

  def result (message)
    session[:message] = message
    redirect to('/')
  end

  private
  def wrap (body)
    <<-"EOT"
<!DOCTYPE html>
<html>
  <head>
    <title>irmagi</title>
    <style type="text/css">
      .input {
        width: 100%;
        font-size: x-large;
      }
    </style>
    <meta name="viewport" content="width=device-width" />
  </head>
  <body>
    #{body}
  </body>
</html>
EOT
  end
end


class App
  attr_reader :profiles

  def initialize (path, command, name = nil)
    @path = path
    @profiles = Profiles.new

    case command
    when 'server'
      server(name)
    when 'dump'
      dump(name)
    when 'capture'
      capture(name)
    when 'play'
      play(name)
    when 'record'
      record(name)
    when 'list'
      list
    when 'reset'
      reset
    when 'nop'
      # DO NOTHING
    else
      STDERR.puts('Unknow command: %s' % command)
    end
  end

  def irmagi
    @irmagi = @irmagi || IrMagician.new(@path)
  end

  def server (port)
    Server.set :app, self
    Server.set :port, port.to_i
    Server.set :history, []
    Server.run!
  end

  def list
    @profiles.each {|it| STDOUT.puts(it) }
  end

  def dump (name)
    dumped = irmagi.automatic_retry { irmagi.dump }
    json_text = JSON.pretty_generate(dumped)
    if name
      file = @profiles.write(name, dumped)
      STDOUT.puts("Dumped: #{file}")
    else
      STDOUT.puts(json_text)
    end
  end

  def capture (name)
    reset
    STDOUT.puts("Please IR me")
    ok, size = irmagi.capture
    if ok
      STDOUT.puts("OK: #{size} bytes")
      dump(name) if name
      @profiles.update
    else
      STDERR.puts("Fail: #{size}")
    end
  end

  def record (name)
    reset
    json = @profiles.read(name)
    irmagi.automatic_retry {
      irmagi.record(json['scale'], json['data'])
    }
  end

  def play (name)
    record(name) if name
    irmagi.automatic_retry { irmagi.play() }
  end

  def reset
    irmagi.automatic_retry { irmagi.reset() }
  end
end


if ARGV.empty?
  puts(<<EOT)
irmagi <DEV_PATH> <SUB_COMMAND>
EOT
else
  App.new(*ARGV)
end
