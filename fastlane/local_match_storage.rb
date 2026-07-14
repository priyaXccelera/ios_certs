require 'fileutils'
require 'match/module'
require 'match/storage'

# `Match::Storage.register_backend` (used below) only extends the internal
# dispatch table (Match::Storage.backends) that `Match::Storage.from_params`
# consults. It does NOT touch the fastlane `match` ACTION's own separate,
# hardcoded validation of the `storage_mode:` option — that lives in
# match/lib/match/options.rb's `storage_mode` ConfigItem, whose verify_block
# checks `Match.storage_modes.include?(value)` against the fixed array
# defined in match/lib/match/module.rb (%w(git google_cloud s3
# gitlab_secure_files)). Without also patching that list, `match(storage_mode:
# "local_backend", ...)` fails validation before ever reaching our registered
# backend, with "Unsupported storage_mode local_backend, must be in git,
# google_cloud, s3, gitlab_secure_files".
module Match
  def self.storage_modes
    return %w(git google_cloud s3 gitlab_secure_files local_backend)
  end
end

# `match` storage backend that just points at a pre-populated local
# directory instead of a remote repo/bucket. The workflow (build-ipa.yml)
# decrypts the job owner's signing bundle (fetched via git push from the
# backend alongside project.zip — never a live HTTP call) into
# ENV['SIGNING_BUNDLE_DIR'] *before* this Fastfile's `match(...)` call runs,
# and re-zips/encrypts/uploads that same directory as a build artifact
# *after* Fastlane finishes — so this class itself only needs to hand
# `match` the directory to read/write in place; no network code here at all.
module Match
  module Storage
    class LocalDirStorage < Interface
      attr_reader :bundle_dir

      def self.configure(params)
        bundle_dir = ENV['SIGNING_BUNDLE_DIR']
        UI.user_error!("SIGNING_BUNDLE_DIR is not set — required for the local_backend match storage mode") if bundle_dir.to_s.empty?

        return self.new(bundle_dir: bundle_dir)
      end

      def initialize(bundle_dir: nil)
        @bundle_dir = bundle_dir
        FileUtils.mkdir_p(bundle_dir)
      end

      def prefixed_working_directory
        return working_directory
      end

      def download
        return if @working_directory

        self.working_directory = bundle_dir
        existing = Dir.glob(File.join(bundle_dir, "**", "*")).select { |f| File.file?(f) }
        UI.message("[local_match_storage] download: working_directory=#{bundle_dir}, #{existing.length} existing file(s): #{existing.join(', ')}")
      end

      def human_readable_description
        "FrontendX local signing bundle directory (#{bundle_dir})"
      end

      # No-ops: `match` writes/deletes files directly under `bundle_dir`
      # (== working_directory), so there's nothing extra to persist here —
      # the workflow's own "package updated signing bundle" step zips and
      # uploads that same directory as a build artifact after Fastlane runs.
      def upload_files(files_to_upload: [], custom_message: nil)
        UI.message("[local_match_storage] upload_files called with #{files_to_upload.length} file(s): #{files_to_upload.join(', ')}")
      end

      def delete_files(files_to_delete: [], custom_message: nil)
        UI.message("[local_match_storage] delete_files called with #{files_to_delete.length} file(s): #{files_to_delete.join(', ')}")
      end

      # No-op: the base Interface#clear_changes does
      # `FileUtils.rm_rf(self.working_directory)`, which is correct for
      # git/s3/gcloud backends (working_directory there is a disposable temp
      # clone) but catastrophic here — working_directory IS bundle_dir, the
      # persistent SIGNING_BUNDLE_DIR the workflow decrypted the user's real
      # cert/profile into. `Match::Runner#run` calls storage.clear_changes
      # in an `ensure`, i.e. after EVERY match() call including the Fastfile's
      # readonly-probe attempt — left un-overridden, this wiped the signing
      # bundle before it could ever be reused or re-persisted, guaranteeing a
      # fresh Apple distribution cert was minted on every single build until
      # the team's 2-cert limit was exhausted.
      def clear_changes
        self.working_directory = nil
      end

      def skip_docs
        true
      end

      def list_files(file_name: "", file_ext: "")
        Dir[File.join(working_directory, "**", file_name, "*.#{file_ext}")]
      end

      def generate_matchfile_content(template: nil)
        "storage_mode(\"local_backend\")"
      end
    end
  end
end
