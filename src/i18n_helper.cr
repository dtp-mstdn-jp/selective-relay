require "citrine-i18n"

module I18nHelper
  def t(key : String, options : Hash | NamedTuple? = nil, force_locale = I18n.config.locale, count = nil, default = nil, iter = nil) : String
    I18n.translate(key: key, options: options, force_locale: force_locale, count: count, default: default, iter: iter)
  end
end
