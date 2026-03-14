//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI

// MARK: - sTalk Centralized Theme Colors

enum StalkTheme {
    /// Primary accent color (blue)
    static let accent = Color(red: 0.38, green: 0.42, blue: 0.96)

    /// UIKit version of accent
    static let accentUIColor = UIColor(red: 0.38, green: 0.42, blue: 0.96, alpha: 1)

    /// Check if cosmos theme is active
    static var isCosmos: Bool {
        UserDefaults.standard.string(forKey: "stalk_design_theme") ?? "cosmos" == "cosmos"
    }
}

// MARK: - sTalk Localized Strings

enum SL10n {
    // MARK: - Tabs
    static let tabContacts = NSLocalizedString("stalk_tab_contacts", tableName: "Localizable", value: "Контакты", comment: "Contacts tab title")
    static let tabCalls = NSLocalizedString("stalk_tab_calls", tableName: "Localizable", value: "Звонки", comment: "Calls tab title")
    static let tabChats = NSLocalizedString("stalk_tab_chats", tableName: "Localizable", value: "Чаты", comment: "Chats tab title")
    static let tabApps = NSLocalizedString("stalk_tab_apps", tableName: "Localizable", value: "Приложения", comment: "Apps tab title")
    static let tabSettings = NSLocalizedString("stalk_tab_settings", tableName: "Localizable", value: "Настройки", comment: "Settings tab title")

    // MARK: - Attachment Picker
    static let attachCamera = NSLocalizedString("stalk_attach_camera", tableName: "Localizable", value: "Камера", comment: "Camera attachment option")
    static let attachGallery = NSLocalizedString("stalk_attach_gallery", tableName: "Localizable", value: "Галерея", comment: "Gallery attachment option")
    static let attachFile = NSLocalizedString("stalk_attach_file", tableName: "Localizable", value: "Файл", comment: "File attachment option")
    static let attachLocation = NSLocalizedString("stalk_attach_location", tableName: "Localizable", value: "Локация", comment: "Location attachment option")
    static let attachPoll = NSLocalizedString("stalk_attach_poll", tableName: "Localizable", value: "Опрос", comment: "Poll attachment option")
    static let attachFormat = NSLocalizedString("stalk_attach_format", tableName: "Localizable", value: "Формат", comment: "Text formatting attachment option")

    // MARK: - Contacts
    static let contactsAll = NSLocalizedString("stalk_contacts_all", tableName: "Localizable", value: "Все", comment: "All contacts filter")
    static let contactsOnline = NSLocalizedString("stalk_contacts_online", tableName: "Localizable", value: "В сети", comment: "Online contacts filter")
    static let contactsFavorites = NSLocalizedString("stalk_contacts_favorites", tableName: "Localizable", value: "Избранные", comment: "Favorite contacts filter")
    static let contactsSortByName = NSLocalizedString("stalk_contacts_sort_name", tableName: "Localizable", value: "По имени", comment: "Sort contacts by name")
    static let contactsSortByTime = NSLocalizedString("stalk_contacts_sort_time", tableName: "Localizable", value: "По времени", comment: "Sort contacts by time")
    static let contactsOnlineStatus = NSLocalizedString("stalk_contacts_online_status", tableName: "Localizable", value: "в сети", comment: "Online status indicator")
    static let contactsOffline = NSLocalizedString("stalk_contacts_offline", tableName: "Localizable", value: "не в сети", comment: "Offline status")
    static let contactsJustNow = NSLocalizedString("stalk_contacts_just_now", tableName: "Localizable", value: "был(а) только что", comment: "Just now status")
    static let contactsNoContacts = NSLocalizedString("stalk_contacts_empty", tableName: "Localizable", value: "Нет контактов", comment: "No contacts message")
    static let contactsEmptyHint = NSLocalizedString("stalk_contacts_empty_hint", tableName: "Localizable", value: "Начните чат с кем-нибудь, чтобы добавить контакт", comment: "Contacts empty state hint")

    static func contactsMinutesAgo(_ minutes: Int) -> String {
        String(format: NSLocalizedString("stalk_contacts_minutes_ago", tableName: "Localizable", value: "был(а) %d мин. назад", comment: "Minutes ago status"), minutes)
    }

    static func contactsHoursAgo(_ hours: Int) -> String {
        String(format: NSLocalizedString("stalk_contacts_hours_ago", tableName: "Localizable", value: "был(а) %d ч. назад", comment: "Hours ago status"), hours)
    }

    static func contactsLastSeen(_ date: String) -> String {
        String(format: NSLocalizedString("stalk_contacts_last_seen", tableName: "Localizable", value: "был(а) %@", comment: "Last seen date"), date)
    }

    static func contactsAllCount(_ count: Int) -> String {
        String(format: NSLocalizedString("stalk_contacts_all_count", tableName: "Localizable", value: "Все %d", comment: "All contacts with count"), count)
    }

    static func contactsOnlineCount(_ count: Int) -> String {
        String(format: NSLocalizedString("stalk_contacts_online_count", tableName: "Localizable", value: "В сети %d", comment: "Online contacts with count"), count)
    }

    static func contactsFavoritesCount(_ count: Int) -> String {
        String(format: NSLocalizedString("stalk_contacts_favorites_count", tableName: "Localizable", value: "Избранные %d", comment: "Favorite contacts with count"), count)
    }

    // MARK: - Calls
    static let callsAll = NSLocalizedString("stalk_calls_all", tableName: "Localizable", value: "Все", comment: "All calls filter")
    static let callsMissed = NSLocalizedString("stalk_calls_missed", tableName: "Localizable", value: "Пропущенные", comment: "Missed calls filter")
    static let callsEmpty = NSLocalizedString("stalk_calls_empty", tableName: "Localizable", value: "Нет звонков", comment: "No calls message")
    static let callsEmptyHint = NSLocalizedString("stalk_calls_empty_hint", tableName: "Localizable", value: "История звонков будет отображаться здесь", comment: "Calls empty state hint")
    static let callDefault = NSLocalizedString("stalk_call_default_name", tableName: "Localizable", value: "Звонок", comment: "Default call name")

    // MARK: - Call Screen
    static let callHand = NSLocalizedString("stalk_call_hand", tableName: "Localizable", value: "рука", comment: "Raise hand button")
    static let callCamera = NSLocalizedString("stalk_call_camera", tableName: "Localizable", value: "камера", comment: "Camera toggle button")
    static let callMicOn = NSLocalizedString("stalk_call_mic_on", tableName: "Localizable", value: "вкл. микр.", comment: "Microphone on label")
    static let callMic = NSLocalizedString("stalk_call_mic", tableName: "Localizable", value: "микрофон", comment: "Microphone label")
    static let callSpeaker = NSLocalizedString("stalk_call_speaker", tableName: "Localizable", value: "динамик", comment: "Speaker label")
    static let callPhone = NSLocalizedString("stalk_call_phone", tableName: "Localizable", value: "телефон", comment: "Phone speaker label")
    static let callEnd = NSLocalizedString("stalk_call_end", tableName: "Localizable", value: "завершить", comment: "End call button")
    static let callBack = NSLocalizedString("stalk_call_back", tableName: "Localizable", value: "Назад", comment: "Back button on call screen")
    static let callCalling = NSLocalizedString("stalk_call_calling", tableName: "Localizable", value: "Вызов...", comment: "Calling state")
    static let callReconnecting = NSLocalizedString("stalk_call_reconnecting", tableName: "Localizable", value: "Переподключение...", comment: "Reconnecting state")
    static let callVoiceCall = NSLocalizedString("stalk_call_voice_call", tableName: "Localizable", value: "Голосовой вызов", comment: "Voice call accessibility")

    // MARK: - Chat / Room Actions
    static let actionRemoveFavorite = NSLocalizedString("stalk_action_remove_favorite", tableName: "Localizable", value: "Убрать", comment: "Remove from favorites")
    static let actionAddFavorite = NSLocalizedString("stalk_action_add_favorite", tableName: "Localizable", value: "Избранное", comment: "Add to favorites")
    static let actionArchive = NSLocalizedString("stalk_action_archive", tableName: "Localizable", value: "Архив", comment: "Archive chat")
    static let actionUnmute = NSLocalizedString("stalk_action_unmute", tableName: "Localizable", value: "Вкл. звук", comment: "Unmute notifications")
    static let actionMute = NSLocalizedString("stalk_action_mute", tableName: "Localizable", value: "Без звука", comment: "Mute notifications")
    static let actionSettings = NSLocalizedString("stalk_action_settings", tableName: "Localizable", value: "Настройки", comment: "Room settings")
    static let actionDelete = NSLocalizedString("stalk_action_delete", tableName: "Localizable", value: "Удалить", comment: "Delete action")
    static let actionCancel = NSLocalizedString("stalk_action_cancel", tableName: "Localizable", value: "Отмена", comment: "Cancel action")
    static let actionSave = NSLocalizedString("stalk_action_save", tableName: "Localizable", value: "Сохранить", comment: "Save action")
    static let actionUndo = NSLocalizedString("stalk_action_undo", tableName: "Localizable", value: "Отменить", comment: "Undo action")
    static let actionClear = NSLocalizedString("stalk_action_clear", tableName: "Localizable", value: "Очистить", comment: "Clear action")
    static let actionBack = NSLocalizedString("stalk_action_back", tableName: "Localizable", value: "Вернуться", comment: "Return/back action")
    static let actionUnarchive = NSLocalizedString("stalk_action_unarchive", tableName: "Localizable", value: "Разархивировать", comment: "Unarchive action")
    static let actionUnarchiveShort = NSLocalizedString("stalk_action_unarchive_short", tableName: "Localizable", value: "Разархив.", comment: "Short unarchive label")

    // MARK: - Home / Chats
    static let chatsRecent = NSLocalizedString("stalk_chats_recent", tableName: "Localizable", value: "Недавние", comment: "Recent chats section")
    static let chatArchived = NSLocalizedString("stalk_chat_archived", tableName: "Localizable", value: "Чат архивирован", comment: "Chat archived message")
    static let archiveTitle = NSLocalizedString("stalk_archive_title", tableName: "Localizable", value: "Архив", comment: "Archive screen title")
    static let archiveEmpty = NSLocalizedString("stalk_archive_empty", tableName: "Localizable", value: "Архив пуст", comment: "Empty archive message")

    // MARK: - Settings
    static let settingsPhoto = NSLocalizedString("stalk_settings_photo", tableName: "Localizable", value: "Фото", comment: "Photo section in settings")
    static let settingsName = NSLocalizedString("stalk_settings_name", tableName: "Localizable", value: "Имя", comment: "Name section in settings")
    static let settingsChangePhoto = NSLocalizedString("stalk_settings_change_photo", tableName: "Localizable", value: "Изменить фото", comment: "Change photo action")
    static let settingsChangeName = NSLocalizedString("stalk_settings_change_name", tableName: "Localizable", value: "Изменить имя", comment: "Change name action")
    static let settingsAccount = NSLocalizedString("stalk_settings_account", tableName: "Localizable", value: "Аккаунт", comment: "Account section header")
    static let settingsPrivacy = NSLocalizedString("stalk_settings_privacy", tableName: "Localizable", value: "Приватность", comment: "Privacy section header")
    static let settingsAppearance = NSLocalizedString("stalk_settings_appearance", tableName: "Localizable", value: "Внешний вид", comment: "Appearance section header")
    static let settingsSupport = NSLocalizedString("stalk_settings_support", tableName: "Localizable", value: "Поддержка", comment: "Support section header")
    static let settingsStorage = NSLocalizedString("stalk_settings_storage", tableName: "Localizable", value: "Хранилище", comment: "Storage section header")
    static let settingsCacheAndData = NSLocalizedString("stalk_settings_cache_data", tableName: "Localizable", value: "Кеш и данные", comment: "Cache and data label")
    static let settingsThemeDesign = NSLocalizedString("stalk_settings_theme_design", tableName: "Localizable", value: "Тема дизайна", comment: "Design theme label")
    static let settingsThemeCosmos = NSLocalizedString("stalk_settings_theme_cosmos", tableName: "Localizable", value: "Космос", comment: "Cosmos theme option")
    static let settingsThemeClassic = NSLocalizedString("stalk_settings_theme_classic", tableName: "Localizable", value: "Классика", comment: "Classic theme option")

    // MARK: - Cache & Storage
    static let cacheUsage = NSLocalizedString("stalk_cache_usage", tableName: "Localizable", value: "Использование", comment: "Usage section header")
    static let cacheApiData = NSLocalizedString("stalk_cache_api_data", tableName: "Localizable", value: "Кеш API данных", comment: "API data cache label")
    static let cacheImages = NSLocalizedString("stalk_cache_images", tableName: "Localizable", value: "Кеш изображений", comment: "Image cache label")
    static let cacheRecordings = NSLocalizedString("stalk_cache_recordings", tableName: "Localizable", value: "Скачанные записи", comment: "Downloaded recordings label")
    static let cacheTotal = NSLocalizedString("stalk_cache_total", tableName: "Localizable", value: "Всего", comment: "Total size label")
    static let cacheClearApi = NSLocalizedString("stalk_cache_clear_api", tableName: "Localizable", value: "Очистить кеш API и записи", comment: "Clear API cache action")
    static let cacheClearImages = NSLocalizedString("stalk_cache_clear_images", tableName: "Localizable", value: "Очистить кеш изображений", comment: "Clear image cache action")
    static let cacheClearAll = NSLocalizedString("stalk_cache_clear_all", tableName: "Localizable", value: "Очистить все данные и перезагрузить", comment: "Clear all data action")
    static let cacheActions = NSLocalizedString("stalk_cache_actions", tableName: "Localizable", value: "Действия", comment: "Actions section header")
    static let cacheClearAllWarning = NSLocalizedString("stalk_cache_clear_all_warning", tableName: "Localizable", value: "Очистка всех данных удалит кеш, скачанные файлы и синхронизированные данные. Приложение перезагрузится.", comment: "Clear all data warning")
    static let cacheClearAllConfirm = NSLocalizedString("stalk_cache_clear_all_confirm", tableName: "Localizable", value: "Очистить все данные?", comment: "Clear all confirmation title")
    static let cacheClearAndRestart = NSLocalizedString("stalk_cache_clear_restart", tableName: "Localizable", value: "Очистить и перезагрузить", comment: "Clear and restart action")
    static let cacheClearConfirmMessage = NSLocalizedString("stalk_cache_clear_confirm_message", tableName: "Localizable", value: "Все кешированные данные будут удалены. Приложение перезагрузится для повторной синхронизации.", comment: "Clear confirmation message")

    // MARK: - Meetings
    static let meetingTitle = NSLocalizedString("stalk_meeting_title", tableName: "Localizable", value: "Встреча", comment: "Meeting type label")
    static let meetingCall = NSLocalizedString("stalk_meeting_call", tableName: "Localizable", value: "Звонок", comment: "Call type label")
    static let meetingAll = NSLocalizedString("stalk_meeting_all", tableName: "Localizable", value: "Все", comment: "All meetings filter")
    static let meetingTime = NSLocalizedString("stalk_meeting_time", tableName: "Localizable", value: "Время", comment: "Time column header")
    static let meetingEvent = NSLocalizedString("stalk_meeting_event", tableName: "Localizable", value: "Событие", comment: "Event column header")
    static let meetingCalendar = NSLocalizedString("stalk_meeting_calendar", tableName: "Localizable", value: "Календарь", comment: "Calendar screen title")
    static let meetingNew = NSLocalizedString("stalk_meeting_new", tableName: "Localizable", value: "Новая встреча", comment: "New meeting title")
    static let meetingEdit = NSLocalizedString("stalk_meeting_edit", tableName: "Localizable", value: "Редактировать", comment: "Edit meeting title")
    static let meetingNamePlaceholder = NSLocalizedString("stalk_meeting_name_placeholder", tableName: "Localizable", value: "Название встречи", comment: "Meeting name placeholder")
    static let meetingDescription = NSLocalizedString("stalk_meeting_description", tableName: "Localizable", value: "Описание", comment: "Description placeholder")
    static let meetingLocation = NSLocalizedString("stalk_meeting_location", tableName: "Localizable", value: "Место или ссылка", comment: "Location/link placeholder")
    static let meetingUnlimited = NSLocalizedString("stalk_meeting_unlimited", tableName: "Localizable", value: "Бессрочная", comment: "Unlimited duration")
    static let meetingStart = NSLocalizedString("stalk_meeting_start", tableName: "Localizable", value: "Начало", comment: "Start time label")
    static let meetingEnd = NSLocalizedString("stalk_meeting_end", tableName: "Localizable", value: "Конец", comment: "End time label")
    static let meetingEndBeforeStart = NSLocalizedString("stalk_meeting_end_before_start", tableName: "Localizable", value: "Время конца раньше начала — будет перенесено на следующий день", comment: "End before start warning")
    static let meetingAllowGuests = NSLocalizedString("stalk_meeting_allow_guests", tableName: "Localizable", value: "Разрешить гостей", comment: "Allow guests toggle")
    static let meetingAddParticipant = NSLocalizedString("stalk_meeting_add_participant", tableName: "Localizable", value: "Добавить участника...", comment: "Add participant placeholder")
    static let meetingSaveError = NSLocalizedString("stalk_meeting_save_error", tableName: "Localizable", value: "Не удалось сохранить встречу", comment: "Save meeting error")

    static func meetingParticipants(_ count: Int) -> String {
        String(format: NSLocalizedString("stalk_meeting_participants", tableName: "Localizable", value: "Участники (%d)", comment: "Participants count"), count)
    }

    // MARK: - Camera
    static let cameraPhoto = NSLocalizedString("stalk_camera_photo", tableName: "Localizable", value: "ФОТО", comment: "Photo mode button")
    static let cameraVideo = NSLocalizedString("stalk_camera_video", tableName: "Localizable", value: "ВИДЕО", comment: "Video mode button")

    // MARK: - Apps / Widgets
    static let appsAll = NSLocalizedString("stalk_apps_all", tableName: "Localizable", value: "Все", comment: "All apps category")
    static let appsProductivity = NSLocalizedString("stalk_apps_productivity", tableName: "Localizable", value: "Продуктивность", comment: "Productivity category")
    static let appsCommunication = NSLocalizedString("stalk_apps_communication", tableName: "Localizable", value: "Связь", comment: "Communication category")
    static let appsTools = NSLocalizedString("stalk_apps_tools", tableName: "Localizable", value: "Инструменты", comment: "Tools category")
    static let appsEmpty = NSLocalizedString("stalk_apps_empty", tableName: "Localizable", value: "Нет приложений", comment: "No apps message")
    static let appsEmptyHint = NSLocalizedString("stalk_apps_empty_hint", tableName: "Localizable", value: "Приложения будут отображаться здесь", comment: "Apps empty state hint")
    static let appsStatistics = NSLocalizedString("stalk_apps_statistics", tableName: "Localizable", value: "Статистика", comment: "Statistics widget name")
    static let appsStatisticsDesc = NSLocalizedString("stalk_apps_statistics_desc", tableName: "Localizable", value: "Статистика использования системы", comment: "Statistics widget description")
    static let appsLoading = NSLocalizedString("stalk_apps_loading", tableName: "Localizable", value: "Загрузка...", comment: "Loading state")

    // MARK: - Auth
    static let authUsername = NSLocalizedString("stalk_auth_username", tableName: "Localizable", value: "Имя пользователя", comment: "Username field placeholder")
    static let authPassword = NSLocalizedString("stalk_auth_password", tableName: "Localizable", value: "Пароль", comment: "Password field placeholder")
    static let authLogin = NSLocalizedString("stalk_auth_login", tableName: "Localizable", value: "Войти", comment: "Login button")
    static let authLoginTitle = NSLocalizedString("stalk_auth_login_title", tableName: "Localizable", value: "Вход в аккаунт", comment: "Login screen title")
    static let authLoginError = NSLocalizedString("stalk_auth_login_error", tableName: "Localizable", value: "Ошибка входа", comment: "Login error title")
    static let authUnknownError = NSLocalizedString("stalk_auth_unknown_error", tableName: "Localizable", value: "Неизвестная ошибка", comment: "Unknown error")
    static let authError = NSLocalizedString("stalk_auth_error", tableName: "Localizable", value: "Ошибка", comment: "Error title")
    static let authTagline = NSLocalizedString("stalk_auth_tagline", tableName: "Localizable", value: "Корпоративный мессенджер с видеозвонками\nдля команд, которые ценят безопасность\nи контроль над данными", comment: "App tagline")
    static let authInvalidCredentials = NSLocalizedString("stalk_auth_invalid_credentials", tableName: "Localizable", value: "Неверный логин или пароль", comment: "Invalid credentials error")

    static func authLoginFailed(_ error: String) -> String {
        String(format: NSLocalizedString("stalk_auth_login_failed", tableName: "Localizable", value: "Не удалось завершить авторизацию: %@", comment: "Login failed message"), error)
    }

    static func authVersion(_ version: String) -> String {
        String(format: NSLocalizedString("stalk_auth_version", tableName: "Localizable", value: "Версия %@", comment: "Version label"), version)
    }

    // MARK: - Meetings (remaining)
    static let meetingNow = NSLocalizedString("stalk_meeting_now", tableName: "Localizable", value: "Сейчас", comment: "Now indicator")
    static let meetingNoMore = NSLocalizedString("stalk_meeting_no_more", tableName: "Localizable", value: "Встреч больше нет", comment: "No more meetings")
    static let meetingNoEvents = NSLocalizedString("stalk_meeting_no_events", tableName: "Localizable", value: "Нет событий на этот день", comment: "No events for this day")
    static let meetingCreate = NSLocalizedString("stalk_meeting_create", tableName: "Localizable", value: "Создать встречу", comment: "Create meeting button")
    static let meetingLoadError = NSLocalizedString("stalk_meeting_load_error", tableName: "Localizable", value: "Не удалось загрузить встречи", comment: "Meeting load error")
    static let meetingSearch = NSLocalizedString("stalk_meeting_search", tableName: "Localizable", value: "Поиск...", comment: "Search placeholder")
    static let meetingStartCall = NSLocalizedString("stalk_meeting_start_call", tableName: "Localizable", value: "Начать звонок", comment: "Start call button")
    static let meetingOpen = NSLocalizedString("stalk_meeting_open", tableName: "Localizable", value: "Открытая", comment: "Open meeting label")
    static let meetingAccept = NSLocalizedString("stalk_meeting_accept", tableName: "Localizable", value: "Приму", comment: "Accept RSVP")
    static let meetingDecline = NSLocalizedString("stalk_meeting_decline", tableName: "Localizable", value: "Отклоню", comment: "Decline RSVP")
    static let meetingAccepted = NSLocalizedString("stalk_meeting_accepted", tableName: "Localizable", value: "Принято", comment: "Accepted status")
    static let meetingDeclined = NSLocalizedString("stalk_meeting_declined", tableName: "Localizable", value: "Отклонено", comment: "Declined status")
    static let meetingStatusScheduled = NSLocalizedString("stalk_meeting_status_scheduled", tableName: "Localizable", value: "Запланирована", comment: "Scheduled status")
    static let meetingStatusActive = NSLocalizedString("stalk_meeting_status_active", tableName: "Localizable", value: "Активна", comment: "Active status")
    static let meetingStatusCompleted = NSLocalizedString("stalk_meeting_status_completed", tableName: "Localizable", value: "Завершена", comment: "Completed status")
    static let meetingStatusCancelled = NSLocalizedString("stalk_meeting_status_cancelled", tableName: "Localizable", value: "Отменена", comment: "Cancelled status")
    static let meetingRsvpAccepted = NSLocalizedString("stalk_meeting_rsvp_accepted", tableName: "Localizable", value: "Принял", comment: "RSVP accepted")
    static let meetingRsvpDeclined = NSLocalizedString("stalk_meeting_rsvp_declined", tableName: "Localizable", value: "Отклонил", comment: "RSVP declined")
    static let meetingRsvpPending = NSLocalizedString("stalk_meeting_rsvp_pending", tableName: "Localizable", value: "Ожидает", comment: "RSVP pending")

    static func meetingFree(_ time: String) -> String {
        String(format: NSLocalizedString("stalk_meeting_free", tableName: "Localizable", value: "Свободно %@", comment: "Free time gap"), time)
    }

    static func meetingUntil(_ title: String, _ time: String) -> String {
        String(format: NSLocalizedString("stalk_meeting_until", tableName: "Localizable", value: "До «%@» — %@", comment: "Time until next meeting"), title, time)
    }

    // MARK: - Calendar
    static let calendarWeekdays: [String] = {
        let keys = ["stalk_weekday_mon", "stalk_weekday_tue", "stalk_weekday_wed", "stalk_weekday_thu", "stalk_weekday_fri", "stalk_weekday_sat", "stalk_weekday_sun"]
        let defaults = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]
        return zip(keys, defaults).map { NSLocalizedString($0, tableName: "Localizable", value: $1, comment: "Weekday short") }
    }()
}
