# frozen_string_literal: true

module Authentication
  extend ActiveSupport::Concern

  include ActionController::HttpAuthentication::Token::ControllerMethods, ActionController::HttpAuthentication::Basic::ControllerMethods
  include Cookies

  def authenticate_with_token!
    case
    when has_bearer_credentials?
      authenticate_or_request_with_http_token(&method(:http_token_authenticator))
    when has_basic_credentials?
      authenticate_or_request_with_http_basic(&method(:http_basic_authenticator))
    when has_license_credentials?
      authenticate_or_request_with_http_license(&method(:http_license_authenticator))
    when has_cookie_credentials?
      authenticate_or_request_with_http_cookie(&method(:http_cookie_authenticator))
    else
      authenticate_or_request_with_query_token(&method(:query_token_authenticator))
    end
  end

  def authenticate_with_token
    case
    when has_bearer_credentials?
      authenticate_with_http_token(&method(:http_token_authenticator))
    when has_basic_credentials?
      authenticate_with_http_basic(&method(:http_basic_authenticator))
    when has_license_credentials?
      authenticate_with_http_license(&method(:http_license_authenticator))
    when has_cookie_credentials?
      authenticate_with_http_cookie(&method(:http_cookie_authenticator))
    else
      authenticate_with_query_token(&method(:query_token_authenticator))
    end
  end

  def authenticate_with_password!
    authenticate_or_request_with_http_basic(&method(:http_password_authenticator))
  end

  def authenticate_with_password
    authenticate_with_http_basic(&method(:http_password_authenticator))
  end

  def authenticate_with_password_or_token!
    if has_password_credentials?
      authenticate_with_password!
    else
      authenticate_with_token!
    end
  end

  def authenticate_with_password_or_token
    if has_password_credentials?
      authenticate_with_password
    else
      authenticate_with_token
    end
  end

  private

  def authenticate_or_request_with_http_cookie(&auth_procedure)
    authenticate_with_http_cookie(&auth_procedure) || request_http_token_authentication
  end

  def authenticate_with_http_cookie(&auth_procedure)
    session_id = cookies.encrypted[:session_id]

    auth_procedure.call(session_id)
  end

  def authenticate_or_request_with_query_token(&auth_procedure)
    authenticate_with_query_token(&auth_procedure) || request_http_token_authentication
  end

  def authenticate_with_query_token(&auth_procedure)
    query_token = request.query_parameters[:token] ||
                  request.query_parameters[:auth]

    auth_procedure.call(query_token)
  end

  def authenticate_or_request_with_http_license(&auth_procedure)
    authenticate_with_http_license(&auth_procedure) || request_http_token_authentication
  end

  def authenticate_with_http_license(&auth_procedure)
    license_key = request.authorization.to_s.split(' ', 2).second

    auth_procedure.call(license_key)
  end

  def query_token_authenticator(query_token)
    return nil if
      current_account.nil? || query_token.blank?

    username, password = query_token.split(':', 2)

    case username
    when 'license'
      http_license_authenticator(password)
    when 'token'
      http_token_authenticator(password)
    else
      # NOTE(ezekg) For backwards compatibility
      http_token_authenticator(username)
    end
  end

  def http_cookie_authenticator(session_id)
    return nil if
      current_account.nil? || session_id.blank?

    session = current_account.sessions.for_environment(current_environment)
                                      .preload(:token, :bearer)
                                      .find_by(
                                        id: session_id,
                                      )

    @current_http_scheme = :session
    @current_http_token  = nil

    raise Keygen::Error::UnauthorizedError.new(code: 'SESSION_INVALID') if
      session.nil? || session.bearer.nil?

    raise Keygen::Error::UnauthorizedError.new(code: 'SESSION_EXPIRED', detail: 'Session is expired') if
      session.expired?

    raise Keygen::Error::ForbiddenError.new(code: 'USER_BANNED', detail: 'User is banned') if
      session.bearer.respond_to?(:banned?) && session.bearer.banned?

    case
    when session.bearer.has_role?(:license)
      raise Keygen::Error::ForbiddenError.new(code: 'SESSION_NOT_ALLOWED', detail: 'Session authentication is not allowed by policy') unless
        session.bearer.supports_session_auth?
    end

    if session.last_used_at.nil? || session.last_used_at.before?(1.hour.ago)
      session.expiry += 1.hour if session.expires_in?(1.hour) # extend expiry while in use until MAX_AGE
      session.update(
        last_used_at: Time.current,
        user_agent: request.user_agent,
        ip: request.remote_ip,
      )

      set_session_id_cookie(session) if session.expiry_previously_changed?
    end

    # FIXME(ezekg) use Current everywhere instead of current ivars
    Current.session = @current_session = session
    Current.token   = @current_token   = session.token
    Current.bearer  = @current_bearer  = session.bearer
  end

  def http_password_authenticator(username = nil, password = nil)
    return nil if
      current_account.nil?

    # save a query in case the username isn't a valid email
    unless username in EMAIL_RE => email
      raise Keygen::Error::UnauthorizedError.new(
        detail: 'email is required',
        code: 'EMAIL_REQUIRED',
        header: 'Authorization',
      )
    end

    # single-sign-on is checked before the user lookup to support jit-provisioning
    if current_account.sso? && current_account.sso_for?(email)
      redirect = sso_redirect_url_for(email)

      unless redirect.present?
        raise Keygen::Error::UnauthorizedError.new(
          detail: 'single sign on is unsupported',
          code: 'SSO_NOT_SUPPORTED',
          header: 'Authorization',
        )
      end

      raise Keygen::Error::UnauthorizedError.new(
        detail: 'single sign on is required',
        code: 'SSO_REQUIRED',
        header: 'Authorization',
        links: { redirect: },
      )
    end

    user = current_account.users.for_environment(current_environment)
                                .find_by(email: email.downcase)

    @current_http_scheme = :password
    @current_http_token  = nil

    # see below comment i.r.t. leaking user existence being a requirement for determining authn flow
    unless user.present?
      raise Keygen::Error::UnauthorizedError.new(
        detail: 'email must be valid',
        code: 'EMAIL_INVALID',
        header: 'Authorization',
      )
    end

    # assert single-sign-on even for users not matching account's domains e.g. third-party admins
    if user.single_sign_on_enabled?
      redirect = sso_redirect_url_for(user)

      unless redirect.present?
        raise Keygen::Error::UnauthorizedError.new(
          detail: 'single sign on is unsupported',
          code: 'SSO_NOT_SUPPORTED',
          header: 'Authorization',
        )
      end

      raise Keygen::Error::UnauthorizedError.new(
        detail: 'single sign on is required',
        code: 'SSO_REQUIRED',
        header: 'Authorization',
        links: { redirect: },
      )
    end

    # verify password only if the user has one set i.e. they're not a managed user
    unless user.password?
      raise Keygen::Error::UnauthorizedError.new(
        detail: 'password is unsupported',
        code: 'PASSWORD_NOT_SUPPORTED',
        header: 'Authorization',
      )
    end

    # NOTE(ezekg) yes, this leaks existence of a user... but we send this so that we can
    #             determine authn flow for an email e.g. password vs single-sign-on
    if user.password? && password.blank?
      raise Keygen::Error::UnauthorizedError.new(
        detail: 'password is required',
        code: 'PASSWORD_REQUIRED',
        header: 'Authorization',
      )
    end

    # verify second factor before password so that we don't leak correctness
    if user.second_factor_enabled?
      otp = params.dig(:meta, :otp)
      if otp.nil?
        raise Keygen::Error::UnauthorizedError.new(
          detail: 'second factor is required',
          code: 'OTP_REQUIRED',
          pointer: '/meta/otp',
        )
      end

      unless user.verify_second_factor(otp)
        raise Keygen::Error::UnauthorizedError.new(
          detail: 'second factor must be valid',
          code: 'OTP_INVALID',
          pointer: '/meta/otp',
        )
      end
    end

    unless user.authenticate(password)
      raise Keygen::Error::UnauthorizedError.new(
        detail: 'password must be valid',
        code: 'PASSWORD_INVALID',
        header: 'Authorization',
      )
    end

    Current.bearer = @current_bearer = user
  end

  def http_basic_authenticator(username = nil, password = nil)
    return nil if
      current_account.nil? || username.blank? && password.blank?

    case username
    when 'license'
      http_license_authenticator(password)
    when 'token'
      http_token_authenticator(password)
    else
      # NOTE(ezekg) For backwards compatibility
      http_token_authenticator(username)
    end
  end

  def http_token_authenticator(http_token = nil, options = nil)
    return nil if
      current_account.nil? || http_token.blank?

    # Make sure token matches our expected format. This is also here to help users
    # who may be mistakenly using a UUID as a token, which is a common mistake.
    if http_token.present? && http_token =~ UUID_RE
      raise Keygen::Error::UnauthorizedError.new(
        detail: "Token format is invalid (make sure that you're providing a token value, not a token's UUID identifier)",
        code: 'TOKEN_FORMAT_INVALID',
      )
    end

    @current_http_scheme = :token
    @current_http_token  = http_token
    @current_token       = TokenLookupService.call(
      environment: current_environment,
      account: current_account,
      token: http_token,
    )

    # If a token was provided but was not found, fail early.
    raise Keygen::Error::UnauthorizedError.new(code: 'TOKEN_INVALID') if
      http_token.present? &&
      current_token.nil?

    current_bearer = current_token&.bearer

    # Sanity check
    if (current_bearer.present? && current_bearer.account_id != current_account.id) ||
       (current_token.present? && current_token.account_id != current_account.id)
      Keygen.logger.error "[authentication] Account mismatch: account=#{current_account&.id || 'N/A'} token=#{current_token&.id || 'N/A'} bearer=#{current_bearer&.id || 'N/A'}"

      raise Keygen::Error::UnauthorizedError.new(code: 'TOKEN_INVALID')
    end

    Current.bearer = current_bearer
    Current.token  = current_token

    raise Keygen::Error::UnauthorizedError.new(code: 'TOKEN_EXPIRED', detail: 'Token is expired') if
      current_token&.expired?

    raise Keygen::Error::ForbiddenError.new(code: 'USER_BANNED', detail: 'User is banned') if
      current_bearer.respond_to?(:banned?) &&
      current_bearer.banned?

    case
    when current_bearer&.has_role?(:license)
      raise Keygen::Error::ForbiddenError.new(code: 'TOKEN_NOT_ALLOWED', detail: 'Token authentication is not allowed by policy') unless
        current_bearer.supports_token_auth?
    end

    @current_bearer = current_bearer
  end

  def http_license_authenticator(license_key, options = nil)
    return nil if
      current_account.nil? || license_key.blank?

    @current_http_scheme = :license
    @current_http_token  = license_key
    @current_token       = nil

    current_license = LicenseKeyLookupService.call(
      environment: current_environment,
      account: current_account,
      key: license_key,
    )

    # Fail early if license key was provided but not found
    raise Keygen::Error::UnauthorizedError.new(code: 'LICENSE_INVALID') if
      license_key.present? &&
      current_license.nil?

    # Sanity check
    if current_license.present? && current_license.account_id != current_account.id
     Keygen.logger.error "[authentication] Account mismatch: account=#{current_account&.id || 'N/A'} license=#{current_license&.id || 'N/A'}"

     raise Keygen::Error::UnauthorizedError.new(code: 'LICENSE_INVALID')
    end

    Current.bearer = current_license

    if current_license.present?
      raise Keygen::Error::ForbiddenError.new(code: 'LICENSE_BANNED', detail: 'License is banned') if
        current_license.banned?

      raise Keygen::Error::ForbiddenError.new(code: 'LICENSE_SUSPENDED', detail: 'License is suspended') if
        current_license.suspended?

      raise Keygen::Error::ForbiddenError.new(code: 'LICENSE_EXPIRED', detail: 'License is expired') if
        current_license.revoke_access? &&
        current_license.expired?

      raise Keygen::Error::ForbiddenError.new(code: 'LICENSE_NOT_ALLOWED', detail: 'License key authentication is not allowed by policy') unless
        current_license.supports_license_auth?
    end

    @current_bearer = current_license
  end

  def request_http_token_authentication(realm = 'keygen', message = nil)
    headers['WWW-Authenticate'] = %(Bearer realm="#{realm.gsub(/"/, "")}")

    case
    when current_http_token.blank?
      raise Keygen::Error::UnauthorizedError.new(code: 'TOKEN_MISSING')
    else
      raise Keygen::Error::UnauthorizedError.new(code: 'TOKEN_INVALID')
    end
  end

  def request_http_basic_authentication(realm = 'keygen', message = nil)
    headers['WWW-Authenticate'] = %(Bearer realm="#{realm.gsub(/"/, "")}")

    raise Keygen::Error::UnauthorizedError.new(code: 'TOKEN_INVALID')
  end

  # NOTE(ezekg) we only support cookie authn from portal origin to prevent CSRF
  #
  #             see: https://scotthelme.co.uk/csrf-is-dead/
  def has_cookie_credentials?
    request.origin == Keygen::Portal::ORIGIN && cookies.key?(:session_id)
  end

  def has_bearer_credentials?
    authentication_scheme == 'bearer' || authentication_scheme == 'token'
  end

  def has_basic_credentials?
    authentication_scheme == 'basic'
  end

  def has_license_credentials?
    authentication_scheme == 'license'
  end

  def has_password_credentials?
    return false unless
      has_basic_credentials?

    username, password = Base64.decode64(authentication_value.to_s)
                               .split(':', 2)

    # FIXME(ezekg) this will break if tokens ever include the @ symbol
    username in /@/ and password in String
  end

  def authentication_scheme
    return nil unless
      request.authorization.present?

    auth_parts  = request.authorization.to_s.split(' ', 2)
    auth_scheme = auth_parts.first
    return nil if
      auth_scheme.nil?

    auth_scheme.downcase
  end

  def authentication_value
    return nil unless
      request.authorization.present?

    auth_parts = request.authorization.to_s.split(' ', 2)
    auth_value = auth_parts.second

    auth_value
  end

  def sso_redirect_url(email) = Keygen::EE::SSO.redirect_url(account: current_account, environment: current_environment, callback_url: sso_callback_url, email:)
  def sso_redirect_url_for(user_or_email)
    case user_or_email
    in User => user
      sso_redirect_url(user.email)
    in String => email
      sso_redirect_url(email)
    else
      nil
    end
  end
end
