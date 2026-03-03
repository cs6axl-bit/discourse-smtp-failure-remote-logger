# frozen_string_literal: true

# name: discourse-smtp-failure-remote-logger
# about: Async logs SMTP send failures to a remote PHP endpoint with rich context (recipient email, SMTP provider, exception details).
# version: 1.0.1
# authors: you
# required_version: 3.0.0

enabled_site_setting :smtp_failure_remote_logger_enabled

after_initialize do
  require "net/http"
  require "uri"
  require "json"
  require "socket"
  require "securerandom"
  require "time"

  module ::SmtpFailureRemoteLogger
    PLUGIN_NAME = "discourse-smtp-failure-remote-logger"

    def self.safe_str(v, max = 10_000)
      s = v.to_s
      s = s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "�")
      s.length > max ? s[0, max] : s
    rescue
      "(unserializable)"
    end

    def self.now_iso
      Time.now.utc.iso8601
    end

    def self.hostname
      @hostname ||= (Socket.gethostname rescue nil)
    end

    def self.multisite_db
      if defined?(RailsMultisite::ConnectionManagement)
        RailsMultisite::ConnectionManagement.current_db
      end
    rescue
      nil
    end

    # Best-effort extract SMTP config (what Discourse is configured to use).
    # If you have a multi-smtp-router plugin that swaps settings per message,
    # you can optionally extend this to read from that plugin (Thread.current, headers, etc.).
    def self.current_smtp_config
      {
        address: SiteSetting.smtp_address,
        port: SiteSetting.smtp_port,
        domain: SiteSetting.smtp_domain,
        user_name: SiteSetting.smtp_user_name,
        auth: SiteSetting.smtp_authentication,
        enable_starttls_auto: SiteSetting.smtp_enable_start_tls,
        openssl_verify_mode: SiteSetting.smtp_openssl_verify_mode,
        force_tls: (SiteSetting.respond_to?(:force_tls) ? SiteSetting.force_tls : nil),
      }
    rescue
      {}
    end

    def self.extract_mail_details(mail)
      return {} if mail.nil?

      to = Array(mail.to).compact.map(&:to_s)
      cc = Array(mail.cc).compact.map(&:to_s)
      bcc = Array(mail.bcc).compact.map(&:to_s)
      from = Array(mail.from).compact.map(&:to_s)
      reply_to = Array(mail.reply_to).compact.map(&:to_s)

      {
        to: to,
        cc: cc,
        bcc: bcc,
        from: from,
        reply_to: reply_to,
        subject: safe_str(mail.subject, 2000),
        message_id: safe_str(mail.message_id, 500),
        date: safe_str(mail.date, 200),
        mime_type: safe_str(mail.mime_type, 200),
      }
    rescue => e
      { mail_extract_error: "#{e.class}: #{safe_str(e.message, 2000)}" }
    end

    def self.extract_discourse_user_id(args)
      user_id = nil

      args.each do |a|
        if a.is_a?(Integer)
          user_id ||= a
        elsif defined?(User) && a.is_a?(User)
          user_id ||= a.id
        elsif a.respond_to?(:id) && a.class.name.to_s == "User"
          user_id ||= a.id
        end
      end

      user_id
    rescue
      nil
    end

    def self.enabled?
      SiteSetting.smtp_failure_remote_logger_enabled &&
        SiteSetting.smtp_failure_remote_logger_endpoint_url.present?
    rescue
      false
    end
  end

  class ::Jobs::SmtpFailureRemoteLoggerPost < ::Jobs::Base
    sidekiq_options queue: "low", retry: 10

    def execute(args)
      return unless SiteSetting.smtp_failure_remote_logger_enabled

      endpoint = SiteSetting.smtp_failure_remote_logger_endpoint_url
      return if endpoint.blank?

      uri = URI.parse(endpoint)
      payload = args["payload"] || {}

      payload["sent_at_utc"] ||= ::SmtpFailureRemoteLogger.now_iso
      payload["worker_hostname"] ||= ::SmtpFailureRemoteLogger.hostname
      payload["rails_env"] ||= Rails.env

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = SiteSetting.smtp_failure_remote_logger_timeout_seconds.to_i
      http.read_timeout = SiteSetting.smtp_failure_remote_logger_timeout_seconds.to_i

      req = Net::HTTP::Post.new(uri.request_uri)
      req["Content-Type"] = "application/json"

      api_key = SiteSetting.smtp_failure_remote_logger_api_key
      req["X-API-Key"] = api_key if api_key.present?

      req.body = JSON.generate(payload)

      res = http.request(req)

      unless res.is_a?(Net::HTTPSuccess)
        raise "Remote log endpoint returned #{res.code} #{res.message}: #{res.body.to_s[0, 2000]}"
      end
    end
  end

  module ::SmtpFailureRemoteLogger
    module EmailSenderPatch
      def send(*args)
        super(*args)
      rescue => e
        begin
          mail_obj = nil
          args.each do |a|
            if a.class.name.to_s == "Mail::Message" || (a.respond_to?(:to) && a.respond_to?(:subject))
              mail_obj = a
              break
            end
          end

          mail_obj ||= (instance_variable_defined?(:@message) ? instance_variable_get(:@message) : nil)
          mail_obj ||= (instance_variable_defined?(:@mail) ? instance_variable_get(:@mail) : nil)

          mail_details = ::SmtpFailureRemoteLogger.extract_mail_details(mail_obj)

          primary_recipient =
            (mail_details[:to].is_a?(Array) ? mail_details[:to].first : nil)

          include_emails = SiteSetting.smtp_failure_remote_logger_include_recipient_emails

          unless include_emails
            if mail_details[:to].is_a?(Array)
              mail_details[:to_domains] = mail_details[:to].map { |x| x.to_s.split("@", 2)[1].to_s.downcase }.uniq
              mail_details.delete(:to)
            end
            if mail_details[:cc].is_a?(Array)
              mail_details[:cc_domains] = mail_details[:cc].map { |x| x.to_s.split("@", 2)[1].to_s.downcase }.uniq
              mail_details.delete(:cc)
            end
            if mail_details[:bcc].is_a?(Array)
              mail_details[:bcc_domains] = mail_details[:bcc].map { |x| x.to_s.split("@", 2)[1].to_s.downcase }.uniq
              mail_details.delete(:bcc)
            end
          end

          smtp_cfg = ::SmtpFailureRemoteLogger.current_smtp_config

          discourse_host = (Discourse.current_hostname rescue nil)

          payload = {
            event: "smtp_send_failure",
            plugin: ::SmtpFailureRemoteLogger::PLUGIN_NAME,
            uuid: SecureRandom.uuid,
            occurred_at_utc: ::SmtpFailureRemoteLogger.now_iso,
            discourse_hostname: discourse_host,
            multisite_db: ::SmtpFailureRemoteLogger.multisite_db,
            server_hostname: ::SmtpFailureRemoteLogger.hostname,

            primary_recipient: (include_emails ? primary_recipient : nil),

            mail: mail_details,
            smtp: smtp_cfg,

            exception: {
              class: e.class.name,
              message: ::SmtpFailureRemoteLogger.safe_str(e.message, 8000),
              backtrace: (e.backtrace || [])[0, SiteSetting.smtp_failure_remote_logger_backtrace_lines.to_i],
            },

            ruby: RUBY_VERSION,
            rails: Rails.version,
          }

          user_id = ::SmtpFailureRemoteLogger.extract_discourse_user_id(args)
          payload[:user_id] = user_id if user_id

          if ::SmtpFailureRemoteLogger.enabled?
            ::Jobs.enqueue(:smtp_failure_remote_logger_post, payload: payload)
          end
        rescue => log_err
          Rails.logger.warn("[#{::SmtpFailureRemoteLogger::PLUGIN_NAME}] logging failed: #{log_err.class}: #{log_err.message}")
        end

        raise e
      end
    end
  end

  if defined?(::Email::Sender)
    ::Email::Sender.prepend(::SmtpFailureRemoteLogger::EmailSenderPatch)
  else
    Rails.logger.warn("[#{::SmtpFailureRemoteLogger::PLUGIN_NAME}] Email::Sender not found; patch not applied")
  end
end
