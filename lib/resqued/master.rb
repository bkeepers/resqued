require 'resqued/backoff'
require 'resqued/listener_proxy'
require 'resqued/logging'
require 'resqued/pidfile'
require 'resqued/procline_version'
require 'resqued/sleepy'

module Resqued
  # The master process.
  # * Spawns a listener.
  # * Tracks all work. (IO pipe from listener.)
  # * Handles signals.
  class Master
    include Resqued::Logging
    include Resqued::Pidfile
    include Resqued::ProclineVersion
    include Resqued::Sleepy

    def initialize(options)
      @config_paths = options.fetch(:config_paths)
      @pidfile      = options.fetch(:master_pidfile) { nil }
      @status_pipe  = options.fetch(:status_pipe) { nil }
      @listener_backoff = Backoff.new
      @listeners_created = 0
    end

    # Public: Starts the master process.
    def run(ready_pipe = nil)
      report_unexpected_exits
      with_pidfile(@pidfile) do
        write_procline
        install_signal_handlers
        if ready_pipe
          ready_pipe.syswrite($$.to_s)
          ready_pipe.close rescue nil
        end
        go_ham
      end
      no_more_unexpected_exits
    end

    # Private: dat main loop.
    def go_ham
      loop do
        read_listeners
        reap_all_listeners(Process::WNOHANG)
        start_listener unless @paused
        case signal = SIGNAL_QUEUE.shift
        when nil
          yawn(@listener_backoff.how_long? || 30.0)
        when :INFO
          dump_object_counts
        when :HUP
          reopen_logs
          log "Restarting listener with new configuration and application."
          prepare_new_listener
        when :USR2
          log "Pause job processing"
          @paused = true
          kill_listener(:QUIT, @current_listener)
          @current_listener = nil
        when :CONT
          log "Resume job processing"
          @paused = false
          kill_all_listeners(:CONT)
        when :INT, :TERM, :QUIT
          log "Shutting down..."
          kill_all_listeners(signal)
          wait_for_workers
          break
        end
      end
    end

    # Private.
    def dump_object_counts
      log GC.stat.inspect
      counts = {}
      total = 0
      ObjectSpace.each_object do |o|
        count = counts[o.class.name] || 0
        counts[o.class.name] = count + 1
        total += 1
      end
      top = 10
      log "#{total} objects. top #{top}:"
      counts.sort_by { |name, count| count }.reverse.each_with_index do |(name, count), i|
        if i < top
          diff = ""
          if last = @last_counts && @last_counts[name]
            diff = " (#{'%+d' % (count - last)})"
          end
          log "   #{count} #{name}#{diff}"
        end
      end
      @last_counts = counts
      log GC.stat.inspect
    rescue => e
      log "Error while counting objects: #{e}"
    end

    # Private: Map listener pids to ListenerProxy objects.
    def listener_pids
      @listener_pids ||= {}
    end

    # Private: All the ListenerProxy objects.
    def all_listeners
      listener_pids.values
    end

    def start_listener
      return if @current_listener || @listener_backoff.wait?
      @current_listener = ListenerProxy.new(:config_paths => @config_paths, :old_workers => all_listeners.map { |l| l.running_workers }.flatten, :listener_id => next_listener_id)
      @current_listener.run
      listener_status @current_listener, 'start'
      @listener_backoff.started
      listener_pids[@current_listener.pid] = @current_listener
      write_procline
    end

    def next_listener_id
      @listeners_created += 1
    end

    def read_listeners
      all_listeners.each do |l|
        l.read_worker_status(:on_activity => self)
      end
    end

    # Listener message: A worker just started working.
    def worker_started(pid)
      worker_status(pid, 'start')
    end

    # Listener message: A worker just stopped working.
    #
    # Forwards the message to the other listeners.
    def worker_finished(pid)
      worker_status(pid, 'stop')
      all_listeners.each do |other|
        other.worker_finished(pid)
      end
    end

    # Listener message: A listener finished booting, and is ready to start workers.
    #
    # Promotes a booting listener to be the current listener.
    def listener_running(listener)
      listener_status(listener, 'ready')
      if listener == @current_listener
        kill_listener(:QUIT, @last_good_listener)
        @last_good_listener = nil
      else
        # This listener didn't receive the last SIGQUIT we sent.
        # (It was probably sent before the listener had set up its traps.)
        # So kill it again. We have moved on.
        kill_listener(:QUIT, listener)
      end
    end

    # Private: Spin up a new listener.
    #
    # The old one will be killed when the new one is ready for workers.
    def prepare_new_listener
      if @last_good_listener
        # The last_good_listener is still running because we got another HUP before the new listener finished booting.
        # Keep the last_good_listener (where all the workers are) and kill the booting current_listener. We'll start a new one.
        kill_listener(:QUIT, @current_listener)
      else
        @last_good_listener = @current_listener
      end
      # Indicate to `start_listener` that it should start a new listener.
      @current_listener = nil
    end

    def kill_listener(signal, listener)
      listener.kill(signal) if listener
    end

    def kill_all_listeners(signal)
      all_listeners.each do |l|
        l.kill(signal)
      end
    end

    def wait_for_workers
      reap_all_listeners
    end

    def reap_all_listeners(waitpid_flags = 0)
      begin
        lpid, status = Process.waitpid2(-1, waitpid_flags)
        if lpid
          log "Listener exited #{status}"
          if @current_listener && @current_listener.pid == lpid
            @listener_backoff.died
            @current_listener = nil
          end
          dead_listener = listener_pids.delete(lpid)
          listener_status dead_listener, 'stop'
          dead_listener.dispose
          write_procline
        else
          return
        end
      rescue Errno::ECHILD
        return
      end while true
    end

    SIGNALS = [ :HUP, :INT, :USR2, :CONT, :TERM, :QUIT ]
    OPTIONAL_SIGNALS = [ :INFO ]
    OTHER_SIGNALS = [:CHLD, 'EXIT']
    TRAPS = SIGNALS + OPTIONAL_SIGNALS + OTHER_SIGNALS

    SIGNAL_QUEUE = []

    def install_signal_handlers
      trap(:CHLD) { awake }
      SIGNALS.each { |signal| trap(signal) { SIGNAL_QUEUE << signal ; awake } }
      OPTIONAL_SIGNALS.each { |signal| trap(signal) { SIGNAL_QUEUE << signal ; awake } rescue nil }
    end

    def report_unexpected_exits
      trap('EXIT') do
        log("EXIT #{$!.inspect}")
        if $!
          $!.backtrace.each do |line|
            log(line)
          end
        end
      end
    end

    def no_more_unexpected_exits
      trap('EXIT', 'DEFAULT')
    end

    def yawn(duration)
      super(duration, all_listeners.map { |l| l.read_pipe })
    end

    def write_procline
      $0 = "#{procline_version} master [gen #{@listeners_created}] [#{listener_pids.size} running] #{ARGV.join(' ')}"
    end

    def listener_status(listener, status)
      if listener && listener.pid
        status_message('listener', listener.pid, status)
      end
    end

    def worker_status(pid, status)
      status_message('worker', pid, status)
    end

    def status_message(type, pid, status)
      if @status_pipe
        @status_pipe.write("#{type},#{pid},#{status}\n")
      end
    end
  end
end
