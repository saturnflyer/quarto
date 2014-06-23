require "fileutils"
require "yaml"
require "open3"
require "rake/file_list"
require "forwardable"
require "rspec/support"

module GoldenChild
  class Scenario
    include FileUtils
    extend Forwardable

    attr_reader :name, :project_root, :command_history

    def_delegators :configuration, :golden_path, :actual_root

    Validation = Struct.new(:message)
    class FailedValidation < Validation
      def passed?
        false
      end
    end
    class PassedValidation < Validation
      def passed?
        true
      end
    end

    def initialize(name:, project_root: configuration.project_root)
      @name            = name
      @project_root    = Pathname(project_root).expand_path
      @command_history = []
    end

    def populate_from(source_dir, caller=caller)
      Dir.chdir(project_root) do
        raise "Scenario has not been set up" unless actual_path.exist?
        source_dir = Pathname(source_dir)
        unless source_dir.directory?
          fail RuntimeError, "No such directory #{source_dir}", caller
        end

        Dir.foreach(source_dir) do |entry|
          next if %w[. ..].include?(entry)
          copy_entry source_dir + entry, actual_path + entry
        end
      end
    end

    def run(*args, allow_fail: false, caller: caller, ** options)
      options[:chdir]        ||= actual_path.to_s
      stdout, stderr, status = Open3.capture3(*args, ** options)
      command_history.push(
          command: args, status: status, stdout: stdout, stderr: stderr)
      command_log = ""
      command_log << "\nCommand: #{args}"
      command_log << "\nExited with status #{status.exitstatus}"
      command_log << "\n========== Command STDOUT ==========\n"
      command_log << stdout
      command_log << "\n========== End STDOUT ==========\n"
      command_log << "\n========== Command STDERR ==========\n"
      command_log << stderr
      command_log << "\n========== End STDERR ==========\n"
      (control_dir + "commands.log").open("a") do |f|
        f.write(command_log)
      end
      unless status.success? || allow_fail
        fail RuntimeError, command_log, caller
      end
    end

    def validate(*files, ** options)
      paths   = Rake::FileList[*files]
      pass    = true
      message = "No files to validate"
      Dir.chdir(project_root) do
        paths.each do |path|
          master_file  = master_path + path
          actual_file  = actual_path + path
          approval_cmd = "golden approve #{actual_file}"
          message      = ""
          file_pass    = false
          if !actual_file.exist?
            message << "Expected file: #{actual_file}"
            message << "\nto be created, but it was not."
          elsif !actual_file.file?
            message << "Expected: #{actual_file}"
            message << "\n to be a file, but it is a #{actual_file.ftype}."
          elsif !master_file.exist?
            message << "Master: #{master_file}"
            message << "\ndoes not yet exist."
            message << "\nActual file: #{actual_file}"
            message << "\nhas the following content:\n\n"
            message << actual_file.read
            message << "\n\nIf this looks correct, run `#{approval_cmd}`"
          elsif !master_file.file?
            message << "Master: #{master_file}"
            message << "must be a file, but it is a #{master_file.ftype}."
          elsif !compare_file(master_file, actual_file)
            message << "Actual: #{actual_file}"
            message << "\ndiffers from master: #{master_file}"
            message << "\n"
            message << diff(master_file, actual_file)
            message << "\n\nIf the changes look correct, run `#{approval_cmd}`"
          else
            message << "Actual file #{actual_file} matches master #{master_file}"
            file_pass = true
          end
          unless file_pass
            pass = false
            break
          end
        end
      end
      if pass
        PassedValidation.new(message)
      else
        FailedValidation.new(message)
      end
    end

    def diff(master_file, actual_file)
      differ = RSpec::Support::Differ.new
      differ.diff(actual_file.read, master_file.read)
    end

    def setup
      mkpath master_path.parent
      rmtree actual_path
      mkpath actual_path
      mkpath control_dir
    end

    def teardown
    end

    def actual_path
      actual_root + relative_path
    end
    alias_method :root, :actual_path

    def master_path
      golden_path + "master" + relative_path
    end

    def control_dir
      actual_path + ".golden_child"
    end

    def relative_path
      slug
    end

    def slug
      name.downcase.tr_s("^a-z0-9", "-")[0..63]
    end

    def configuration
      ::GoldenChild.configuration
    end
  end
end
