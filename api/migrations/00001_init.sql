-- +goose Up
-- +goose StatementBegin

-- =====================================================================
-- ENUMS
-- =====================================================================

CREATE TYPE expense_category AS ENUM (
    'food',
    'transport',
    'shopping',
    'entertainment',
    'bills',
    'health',
    'education',
    'other'
);

CREATE TYPE friendship_status AS ENUM ('pending', 'accepted', 'blocked');

CREATE TYPE recurring_frequency AS ENUM ('daily', 'weekly', 'monthly', 'yearly');

CREATE TYPE group_type AS ENUM ('permanent', 'temporal');

CREATE TYPE group_role AS ENUM ('owner', 'member');

CREATE TYPE message_type AS ENUM ('text', 'bounty_card', 'system');

CREATE TYPE budget_period AS ENUM ('weekly', 'monthly');


-- =====================================================================
-- USERS & SOCIAL GRAPH
-- =====================================================================

CREATE TABLE users (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    google_id       TEXT UNIQUE NOT NULL,
    email           TEXT UNIQUE NOT NULL,
    username        TEXT NOT NULL,                          -- e.g. "kazu"
    tag             TEXT NOT NULL,                          -- 4-digit "1234"; Discord-style
    display_name    TEXT NOT NULL,
    avatar_id       TEXT NOT NULL DEFAULT 'default_1',      -- key to predefined avatar set
    level           INT  NOT NULL DEFAULT 1,
    xp              INT  NOT NULL DEFAULT 0,
    streak_count    INT  NOT NULL DEFAULT 0,
    last_log_date   DATE,                                   -- last calendar date user logged an expense (in their TZ)
    timezone        TEXT NOT NULL DEFAULT 'Asia/Jakarta',   -- needed to compute "today" correctly
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (username, tag),
    CHECK (char_length(username) BETWEEN 3 AND 24),
    CHECK (tag ~ '^[0-9]{4}$'),
    CHECK (char_length(display_name) BETWEEN 1 AND 32)
);

CREATE INDEX idx_users_username_tag ON users (username, tag);


CREATE TABLE friendships (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    requester_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    addressee_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    status          friendship_status NOT NULL DEFAULT 'pending',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    accepted_at     TIMESTAMPTZ,
    UNIQUE (requester_id, addressee_id),
    CHECK (requester_id <> addressee_id)
);

CREATE INDEX idx_friendships_addressee ON friendships (addressee_id, status);
CREATE INDEX idx_friendships_requester ON friendships (requester_id, status);


-- =====================================================================
-- EXPENSES & RECURRING
-- =====================================================================

CREATE TABLE recurring_expenses (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    amount          BIGINT NOT NULL CHECK (amount > 0),     -- coins (1:1 IDR)
    category        expense_category NOT NULL,
    note            TEXT,
    frequency       recurring_frequency NOT NULL,
    next_occurrence DATE NOT NULL,
    active          BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_recurring_user_active ON recurring_expenses (user_id) WHERE active = TRUE;
CREATE INDEX idx_recurring_due         ON recurring_expenses (next_occurrence) WHERE active = TRUE;


CREATE TABLE expenses (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    amount          BIGINT NOT NULL CHECK (amount > 0),
    category        expense_category NOT NULL,
    note            TEXT,
    is_recurring    BOOLEAN NOT NULL DEFAULT FALSE,         -- TRUE if generated from recurring_expenses
    recurring_id    UUID REFERENCES recurring_expenses(id) ON DELETE SET NULL,
    occurred_at     TIMESTAMPTZ NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    client_id       TEXT                                    -- client-generated UUID for offline-queue idempotency
);

CREATE INDEX idx_expenses_user_occurred  ON expenses (user_id, occurred_at DESC);
CREATE INDEX idx_expenses_user_category  ON expenses (user_id, category);
CREATE UNIQUE INDEX idx_expenses_client_id ON expenses (user_id, client_id) WHERE client_id IS NOT NULL;


-- =====================================================================
-- GROUPS, MEMBERS, INVITES
-- =====================================================================

CREATE TABLE groups (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name                 TEXT NOT NULL,
    type                 group_type NOT NULL,
    created_by           UUID NOT NULL REFERENCES users(id),
    expires_at           TIMESTAMPTZ,                       -- NULL for permanent
    listened_categories  expense_category[] NOT NULL DEFAULT '{}',
    hide_amounts         BOOLEAN NOT NULL DEFAULT FALSE,
    is_locked            BOOLEAN NOT NULL DEFAULT FALSE,
    locked_at            TIMESTAMPTZ,
    final_leaderboard    JSONB,                             -- snapshot saved at lock time
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (
        (type = 'temporal'  AND expires_at IS NOT NULL) OR
        (type = 'permanent' AND expires_at IS NULL)
    ),
    CHECK (char_length(name) BETWEEN 1 AND 48)
);

CREATE INDEX idx_groups_unlocked_temporal
    ON groups (expires_at)
    WHERE type = 'temporal' AND is_locked = FALSE;


CREATE TABLE group_members (
    group_id        UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    user_id         UUID NOT NULL REFERENCES users(id)  ON DELETE CASCADE,
    role            group_role NOT NULL DEFAULT 'member',
    joined_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_read_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),    -- for unread badge
    PRIMARY KEY (group_id, user_id)
);

CREATE INDEX idx_group_members_user ON group_members (user_id);


CREATE TABLE group_invites (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id    UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    code        TEXT UNIQUE NOT NULL,                       -- short URL-safe; e.g. "x9k2-pq1m"
    created_by  UUID NOT NULL REFERENCES users(id),
    expires_at  TIMESTAMPTZ,
    max_uses    INT,
    use_count   INT NOT NULL DEFAULT 0,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_group_invites_code ON group_invites (code);


-- =====================================================================
-- CHAT: MESSAGES & REACTIONS
-- =====================================================================

CREATE TABLE messages (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id        UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    user_id         UUID REFERENCES users(id) ON DELETE SET NULL,    -- NULL for system messages
    type            message_type NOT NULL,
    content         TEXT,                                              -- text body (for type='text')
    expense_id      UUID REFERENCES expenses(id) ON DELETE CASCADE,    -- for type='bounty_card'
    reply_to_id     UUID REFERENCES messages(id) ON DELETE SET NULL,
    metadata        JSONB NOT NULL DEFAULT '{}'::jsonb,                -- flexible payload (system msg subtype, locked-group recap, etc.)
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (
        (type = 'text'         AND content    IS NOT NULL) OR
        (type = 'bounty_card'  AND expense_id IS NOT NULL) OR
        (type = 'system')
    )
);

CREATE INDEX idx_messages_group_created ON messages (group_id, created_at DESC);
CREATE INDEX idx_messages_expense       ON messages (expense_id);


CREATE TABLE reactions (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    message_id      UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    user_id         UUID NOT NULL REFERENCES users(id)    ON DELETE CASCADE,
    reaction_key    TEXT NOT NULL,                          -- 'coin_shower', 'fire', 'skull', 'whale', etc.
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (message_id, user_id, reaction_key)              -- one of each kind per user per message
);

CREATE INDEX idx_reactions_message ON reactions (message_id);


-- =====================================================================
-- BUDGETS, BADGES, SETTINGS
-- =====================================================================

CREATE TABLE budgets (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id               UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    amount                BIGINT NOT NULL CHECK (amount > 0),
    period                budget_period NOT NULL DEFAULT 'weekly',
    broadcast_group_ids   UUID[] NOT NULL DEFAULT '{}',     -- groups to roast you in when blown out
    active                BOOLEAN NOT NULL DEFAULT TRUE,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_budgets_user_active ON budgets (user_id) WHERE active = TRUE;


CREATE TABLE badges (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(id)  ON DELETE CASCADE,
    group_id        UUID REFERENCES groups(id) ON DELETE SET NULL,
    title           TEXT NOT NULL,                          -- "The Whale", "The Sniper", "Iron Wallet"
    badge_key       TEXT NOT NULL,                          -- normalized key for icon lookup
    description     TEXT,
    xp_awarded      INT  NOT NULL DEFAULT 0,
    awarded_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_badges_user ON badges (user_id, awarded_at DESC);


CREATE TABLE notification_settings (
    user_id         UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    settings        JSONB NOT NULL DEFAULT '{
        "chat_messages": true,
        "reactions": true,
        "bounty_cards": true,
        "friend_requests": true,
        "budget_blowout": true,
        "group_locked": true,
        "badge_earned": true
    }'::jsonb,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


CREATE TABLE push_subscriptions (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    endpoint        TEXT UNIQUE NOT NULL,
    p256dh          TEXT NOT NULL,
    auth            TEXT NOT NULL,
    user_agent      TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_push_user ON push_subscriptions (user_id);


-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

DROP TABLE IF EXISTS push_subscriptions;
DROP TABLE IF EXISTS notification_settings;
DROP TABLE IF EXISTS badges;
DROP TABLE IF EXISTS budgets;
DROP TABLE IF EXISTS reactions;
DROP TABLE IF EXISTS messages;
DROP TABLE IF EXISTS group_invites;
DROP TABLE IF EXISTS group_members;
DROP TABLE IF EXISTS groups;
DROP TABLE IF EXISTS expenses;
DROP TABLE IF EXISTS recurring_expenses;
DROP TABLE IF EXISTS friendships;
DROP TABLE IF EXISTS users;

DROP TYPE IF EXISTS budget_period;
DROP TYPE IF EXISTS message_type;
DROP TYPE IF EXISTS group_role;
DROP TYPE IF EXISTS group_type;
DROP TYPE IF EXISTS recurring_frequency;
DROP TYPE IF EXISTS friendship_status;
DROP TYPE IF EXISTS expense_category;

-- +goose StatementEnd
