require 'net/http'
require 'uri'
require 'json'
require 'base64'
require 'tmpdir'
require 'fileutils'
require 'zip'
require 'match/storage/interface'

# Stores the `match`-managed certs/profiles as one encrypted blob per user in
# our own backend's database, instead of a shared git repo. Each user's
# bundle is isolated by job_id -> user_id server-side, and encrypted with a
# per-user password (not one shared MATCH_PASSWORD) — see
# app/models.py:AppleDeveloperCredential and
# app/routers/jobs.py: internal_get_match_bundle / internal_put_match_bundle.
#
# Modeled directly on fastlane's own Match::Storage::GitStorage /
# Match::Storage::S3Storage (lib/match/storage/{git,s3}_storage.rb in the
# fastlane gem, pinned to ~> 2.224 per this repo's Gemfile) — confirmed via
# that source that `working_directory` is used FLAT (no team_id subfolder
# nesting), so a single "zip the whole directory" round-trip is sufficient;
# we don't need S3Storage's per-team key-prefixing since each user's bundle
# is already isolated as its own DB row server-side.
module Match
  module Storage
    class HttpStorage < Interface
      attr_reader :team_id
      attr_reader :readonly
      attr_reader :backend_url
      attr_reader :internal_secret
      attr_reader :job_id

      def self.configure(params)
        backend_url = ENV['BACKEND_PUBLIC_URL']
        internal_secret = ENV['IPA_CALLBACK_SECRET']
        job_id = ENV['JOB_ID']

        UI.user_error!("BACKEND_PUBLIC_URL is not set — required for http_backend match storage") if backend_url.to_s.empty?
        UI.user_error!("IPA_CALLBACK_SECRET is not set — required for http_backend match storage") if internal_secret.to_s.empty?
        UI.user_error!("JOB_ID is not set — required for http_backend match storage") if job_id.to_s.empty?

        return self.new(
          team_id: params[:team_id],
          readonly: params[:readonly],
          backend_url: backend_url,
          internal_secret: internal_secret,
          job_id: job_id
        )
      end

      def initialize(team_id: nil, readonly: nil, backend_url: nil, internal_secret: nil, job_id: nil)
        @team_id = team_id
        @readonly = readonly
        @backend_url = backend_url.chomp('/')
        @internal_secret = internal_secret
        @job_id = job_id
      end

      def prefixed_working_directory
        return working_directory
      end

      # Initial "clone" — downloads the user's stored bundle (if any) and
      # unzips it into a fresh local working directory. A user with no
      # bundle yet (first-ever build) gets an EMPTY working directory here,
      # which is exactly what lets `match`'s own `readonly: false` auto-create
      # logic run normally and provision fresh certs/profiles — no separate
      # "init" step needed.
      def download
        return if @working_directory && Dir.exist?(@working_directory)

        self.working_directory = Dir.mktmpdir
        bundle_base64 = fetch_bundle

        if bundle_base64.nil? || bundle_base64.empty?
          UI.message("No existing signing bundle found for this user — match will create fresh certs/profiles.")
          return
        end

        zip_path = File.join(Dir.mktmpdir, "signing_bundle.zip")
        File.binwrite(zip_path, Base64.decode64(bundle_base64))

        Zip::File.open(zip_path) do |zip_file|
          zip_file.each do |entry|
            dest_path = File.join(self.working_directory, entry.name)
            FileUtils.mkdir_p(File.dirname(dest_path))
            entry.extract(dest_path) { true } # overwrite if present
          end
        end
        UI.message("Downloaded and extracted existing signing bundle for this user.")
      end

      def human_readable_description
        "FrontendX backend-managed signing bundle (job #{job_id})"
      end

      def upload_files(files_to_upload: [], custom_message: nil)
        sync_to_backend!
      end

      def delete_files(files_to_delete: [], custom_message: nil)
        sync_to_backend!
      end

      def skip_docs
        true
      end

      def list_files(file_name: "", file_ext: "")
        Dir[File.join(working_directory, "**", file_name, "*.#{file_ext}")]
      end

      def generate_matchfile_content(template: nil)
        "storage_mode(\"http_backend\")"
      end

      private

      # Re-zips the whole working directory and PUTs it back to the backend.
      # Called after `match` has already finished mutating files on disk
      # (both for new/updated files and deletions), so a full re-zip in
      # either callback captures the correct final state either way — we
      # don't need git-style per-file diffing since this isn't git.
      def sync_to_backend!
        zip_path = File.join(Dir.mktmpdir, "signing_bundle.zip")

        Zip::File.open(zip_path, Zip::File::CREATE) do |zip_file|
          Dir.glob(File.join(working_directory, "**", "*")).each do |file|
            next if File.directory?(file)
            relative_path = file.sub("#{working_directory}/", "")
            zip_file.add(relative_path, file)
          end
        end

        bundle_base64 = Base64.strict_encode64(File.binread(zip_path))
        put_bundle(bundle_base64)
        UI.message("Uploaded updated signing bundle to backend.")
      end

      def fetch_bundle
        uri = URI("#{backend_url}/api/v1/jobs/internal/#{job_id}/match-bundle")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == 'https')

        req = Net::HTTP::Get.new(uri)
        req['X-Internal-Secret'] = internal_secret

        resp = http.request(req)
        unless resp.code == '200'
          UI.user_error!("Could not fetch signing bundle from backend (HTTP #{resp.code}): #{resp.body}")
        end

        JSON.parse(resp.body)['bundle_base64']
      end

      def put_bundle(bundle_base64)
        uri = URI("#{backend_url}/api/v1/jobs/internal/#{job_id}/match-bundle")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == 'https')

        req = Net::HTTP::Put.new(uri)
        req['X-Internal-Secret'] = internal_secret
        req['Content-Type'] = 'application/json'
        req.body = { bundle_base64: bundle_base64 }.to_json

        resp = http.request(req)
        unless resp.code == '204'
          UI.user_error!("Could not save signing bundle to backend (HTTP #{resp.code}): #{resp.body}")
        end
      end
    end
  end
end
