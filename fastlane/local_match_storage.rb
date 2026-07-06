require 'fileutils'
require 'match/storage'

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
      end

      def human_readable_description
        "FrontendX local signing bundle directory (#{bundle_dir})"
      end

      # No-ops: `match` writes/deletes files directly under `bundle_dir`
      # (== working_directory), so there's nothing extra to persist here —
      # the workflow's own "package updated signing bundle" step zips and
      # uploads that same directory as a build artifact after Fastlane runs.
      def upload_files(files_to_upload: [], custom_message: nil)
      end

      def delete_files(files_to_delete: [], custom_message: nil)
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
