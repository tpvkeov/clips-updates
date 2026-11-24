-- =============================================================================
-- CLIPS / PAGEBOOK - UNIFIED SUPABASE SCHEMA
-- Supabase Auth + Postgres + RLS + Edge Functions + Backblaze B2 (videos)
-- شغّل الملف ده مرة واحدة في Supabase SQL Editor.
-- =============================================================================
-- ملاحظات مهمة:
--   1) الفيديوهات الكبيرة على Backblaze B2، مش على Supabase Storage.
--   2) Supabase Storage للصور فقط: avatars / banners / media.
--   3) مفاتيح B2 تفضل في Supabase Secrets داخل Edge Functions، مش في الجدول.
--   4) غيّر الإيميل الأدمن في is_admin() و handle_new_user() لو تحب.
--   5) حد التخزين المجاني لـ B2 = 10GB. غيّر limit_bytes في storage_usage لو كبرت.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- حذف الدوال القديمة بأسمائها القديمة عشان إعادة التشغيل تكون آمنة
DROP FUNCTION IF EXISTS public.handle_new_user() CASCADE;
DROP FUNCTION IF EXISTS public.increment_views(TEXT) CASCADE;
DROP FUNCTION IF EXISTS public.get_user_comment_count(TEXT) CASCADE;
DROP FUNCTION IF EXISTS public.get_user_comment_count(UUID) CASCADE;
DROP FUNCTION IF EXISTS public.record_video_view(TEXT, UUID, TEXT, TEXT, INTEGER, INTEGER) CASCADE;
DROP FUNCTION IF EXISTS public.check_upload_limit(UUID, TEXT, BIGINT) CASCADE;
DROP FUNCTION IF EXISTS public.activate_pro_code(UUID, TEXT) CASCADE;
DROP FUNCTION IF EXISTS public.create_pro_code(TEXT, INTEGER, INTEGER) CASCADE;
DROP FUNCTION IF EXISTS public.deactivate_pro_code(UUID) CASCADE;
DROP FUNCTION IF EXISTS public.admin_warn_user(UUID, TEXT) CASCADE;
DROP FUNCTION IF EXISTS public.admin_ban_user(UUID, TEXT) CASCADE;
DROP FUNCTION IF EXISTS public.admin_ban_user(UUID, TEXT, INTEGER) CASCADE;
DROP FUNCTION IF EXISTS public.admin_unban_user(UUID) CASCADE;
DROP FUNCTION IF EXISTS public.admin_toggle_verify(UUID, BOOLEAN) CASCADE;
DROP FUNCTION IF EXISTS public.admin_delete_video(TEXT, TEXT) CASCADE;
DROP FUNCTION IF EXISTS public.admin_ban_video(TEXT, TEXT, TEXT, TIMESTAMPTZ) CASCADE;
DROP FUNCTION IF EXISTS public.admin_delete_post(UUID, TEXT) CASCADE;
DROP FUNCTION IF EXISTS public.admin_pin_post(UUID, BOOLEAN) CASCADE;
DROP FUNCTION IF EXISTS public.get_user_status(UUID) CASCADE;
DROP FUNCTION IF EXISTS public.reserve_vcdn_upload_session(UUID, BIGINT) CASCADE;

DROP VIEW IF EXISTS public.social_feed;


-- =============================================================================
-- 1) PROFILES
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    full_name TEXT,
    avatar_url TEXT,
    banner_url TEXT,
    bio TEXT,
    website TEXT,
    location TEXT,

    -- لون الثيم المختار في صفحة الدخول (ARGB من التطبيق)
    theme_accent_argb BIGINT,

    followers_count BIGINT NOT NULL DEFAULT 0,
    following_count BIGINT NOT NULL DEFAULT 0,

    is_admin BOOLEAN NOT NULL DEFAULT FALSE,
    verified BOOLEAN NOT NULL DEFAULT FALSE,

    -- banned هو اسم قديم، is_banned هو الاسم المعتمد. الاتنين متزامنين بالتريجر.
    banned BOOLEAN NOT NULL DEFAULT FALSE,
    is_banned BOOLEAN NOT NULL DEFAULT FALSE,
    ban_expires_at TIMESTAMPTZ,
    ban_reason TEXT,
    banned_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,

    warning_count INTEGER NOT NULL DEFAULT 0,
    warning_reason TEXT,
    warning_active BOOLEAN NOT NULL DEFAULT FALSE,
    warned_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,

    is_pro BOOLEAN NOT NULL DEFAULT FALSE,
    pro_expires_at TIMESTAMPTZ,
    pro_activated_at TIMESTAMPTZ,

    email_notifications BOOLEAN NOT NULL DEFAULT TRUE,
    dark_mode BOOLEAN NOT NULL DEFAULT TRUE,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- أعمدة توافق مع قاعدة بيانات قديمة
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='theme_accent_argb') THEN ALTER TABLE public.profiles ADD COLUMN theme_accent_argb BIGINT; END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='following_count') THEN ALTER TABLE public.profiles ADD COLUMN following_count BIGINT NOT NULL DEFAULT 0; END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='is_banned') THEN ALTER TABLE public.profiles ADD COLUMN is_banned BOOLEAN NOT NULL DEFAULT FALSE; END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='ban_expires_at') THEN ALTER TABLE public.profiles ADD COLUMN ban_expires_at TIMESTAMPTZ; END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='banned_by') THEN ALTER TABLE public.profiles ADD COLUMN banned_by UUID; END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='warning_count') THEN ALTER TABLE public.profiles ADD COLUMN warning_count INTEGER NOT NULL DEFAULT 0; END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='warned_by') THEN ALTER TABLE public.profiles ADD COLUMN warned_by UUID; END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='is_pro') THEN ALTER TABLE public.profiles ADD COLUMN is_pro BOOLEAN NOT NULL DEFAULT FALSE; END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='pro_expires_at') THEN ALTER TABLE public.profiles ADD COLUMN pro_expires_at TIMESTAMPTZ; END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='pro_activated_at') THEN ALTER TABLE public.profiles ADD COLUMN pro_activated_at TIMESTAMPTZ; END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='email_notifications') THEN ALTER TABLE public.profiles ADD COLUMN email_notifications BOOLEAN NOT NULL DEFAULT TRUE; END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='dark_mode') THEN ALTER TABLE public.profiles ADD COLUMN dark_mode BOOLEAN NOT NULL DEFAULT TRUE; END IF;
END $$;

-- لازم نعرّف is_admin قبل أي سياسة RLS بتستخدمه
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM public.profiles
        WHERE id = auth.uid() AND COALESCE(is_admin, false) = true
    ) OR (
        COALESCE(auth.jwt() ->> 'email', '') = 'probader671@gmail.com'
    );
END;
$$;

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Public profiles are viewable by everyone" ON public.profiles;
CREATE POLICY "Public profiles are viewable by everyone"
    ON public.profiles FOR SELECT USING (true);

DROP POLICY IF EXISTS "Users can insert their own profile" ON public.profiles;
CREATE POLICY "Users can insert their own profile"
    ON public.profiles FOR INSERT WITH CHECK (auth.uid() = id);

DROP POLICY IF EXISTS "Users can update their own profile" ON public.profiles;
CREATE POLICY "Users can update their own profile"
    ON public.profiles FOR UPDATE
    USING (auth.uid() = id)
    WITH CHECK (auth.uid() = id);

DROP POLICY IF EXISTS "Admins can manage any profile" ON public.profiles;
CREATE POLICY "Admins can manage any profile"
    ON public.profiles FOR ALL USING (public.is_admin());


-- =============================================================================
-- 2) HELPER FUNCTIONS (الدوال المساعدة)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.is_banned_now(p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT COALESCE(is_banned, banned, false)
           AND (ban_expires_at IS NULL OR ban_expires_at > now())
    FROM public.profiles
    WHERE id = p_user_id;
$$;

CREATE OR REPLACE FUNCTION public.touch_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.sync_profile_ban_flags()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        NEW.banned := COALESCE(NEW.banned, NEW.is_banned, false);
        NEW.is_banned := NEW.banned;
    ELSE
        IF NEW.is_banned IS DISTINCT FROM OLD.is_banned THEN
            NEW.banned := NEW.is_banned;
        ELSIF NEW.banned IS DISTINCT FROM OLD.banned THEN
            NEW.is_banned := NEW.banned;
        END IF;
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_profiles_sync ON public.profiles;
CREATE TRIGGER trg_profiles_sync
    BEFORE INSERT OR UPDATE ON public.profiles
    FOR EACH ROW EXECUTE FUNCTION public.sync_profile_ban_flags();

DROP TRIGGER IF EXISTS trg_profiles_touch ON public.profiles;
CREATE TRIGGER trg_profiles_touch
    BEFORE UPDATE ON public.profiles
    FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();


-- =============================================================================
-- 3) DEVICE IDENTITY + BANS  (الميزات اللي التطبيق بيجمعها من التليفون)
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.device_identities (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    device_id TEXT NOT NULL,
    mac_address TEXT,
    ip_address TEXT,
    ip_hash TEXT,
    mac_hash TEXT,
    model TEXT,
    kernel_version TEXT,
    baseband_version TEXT,
    fingerprint TEXT NOT NULL UNIQUE,
    extended_fingerprint TEXT NOT NULL,
    first_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS device_identities_user_idx ON public.device_identities(user_id, last_seen_at DESC);
CREATE INDEX IF NOT EXISTS device_identities_extended_idx ON public.device_identities(extended_fingerprint);

ALTER TABLE public.device_identities ENABLE ROW LEVEL SECURITY;
REVOKE INSERT, UPDATE, DELETE ON public.device_identities FROM anon, authenticated;

DROP POLICY IF EXISTS "Users can view their own device records" ON public.device_identities;
CREATE POLICY "Users can view their own device records"
    ON public.device_identities FOR SELECT
    USING (auth.uid() = user_id OR public.is_admin());

CREATE TABLE IF NOT EXISTS public.banned_devices (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    fingerprint TEXT NOT NULL UNIQUE,
    extended_fingerprint TEXT,
    reason TEXT,
    banned_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    expires_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.banned_devices ENABLE ROW LEVEL SECURITY;

-- الفحص من التطبيق يتم عبر RPC is_device_banned، فلا داعي لعرض جدول الحظر للعامة
DROP POLICY IF EXISTS "Anyone can check banned devices" ON public.banned_devices;

DROP POLICY IF EXISTS "Admins manage banned devices" ON public.banned_devices;
CREATE POLICY "Admins manage banned devices"
    ON public.banned_devices FOR ALL USING (public.is_admin());

CREATE TABLE IF NOT EXISTS public.banned_networks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    fingerprint TEXT NOT NULL UNIQUE,
    ip_hash TEXT,
    reason TEXT,
    banned_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    expires_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- لو قاعدة بيانات قديمة فيها UNIQUE على ip_hash، شيك القيد ده عشان ما يفشلش إدخال بصمتين بنفس الـ hash
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN
        SELECT conname FROM pg_constraint
        WHERE conrelid = 'public.banned_networks'::regclass
          AND contype = 'u'
          AND pg_get_constraintdef(oid) ILIKE '%ip_hash%'
    LOOP
        EXECUTE format('ALTER TABLE public.banned_networks DROP CONSTRAINT %I', r.conname);
    END LOOP;
END $$;

ALTER TABLE public.banned_networks ENABLE ROW LEVEL SECURITY;

-- نفس الفكرة: الفحص عبر RPC مش بعرض الجدول
DROP POLICY IF EXISTS "Anyone can check banned networks" ON public.banned_networks;

DROP POLICY IF EXISTS "Admins manage banned networks" ON public.banned_networks;
CREATE POLICY "Admins manage banned networks"
    ON public.banned_networks FOR ALL USING (public.is_admin());

-- تسجيل بصمة الجهاز (يُستدعى من التطبيق قبل/بعد الدخول)
CREATE OR REPLACE FUNCTION public.record_device_identity(
    p_device_id TEXT,
    p_mac_address TEXT,
    p_ip_address TEXT,
    p_model TEXT,
    p_kernel_version TEXT,
    p_baseband_version TEXT,
    p_fingerprint TEXT,
    p_extended_fingerprint TEXT,
    p_user_id UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_id UUID;
    v_ip_hash TEXT;
    v_mac_hash TEXT;
BEGIN
    IF p_fingerprint IS NULL OR length(trim(p_fingerprint)) < 16 THEN
        RAISE EXCEPTION 'invalid device fingerprint' USING ERRCODE = '22023';
    END IF;

    v_ip_hash  := encode(digest(COALESCE(p_ip_address, ''), 'sha256'), 'hex');
    v_mac_hash := encode(digest(COALESCE(p_mac_address, ''), 'sha256'), 'hex');

    INSERT INTO public.device_identities (
        user_id, device_id, mac_address, ip_address, ip_hash, mac_hash,
        model, kernel_version, baseband_version,
        fingerprint, extended_fingerprint, last_seen_at
    )
    VALUES (
        p_user_id, p_device_id, p_mac_address, p_ip_address, v_ip_hash, v_mac_hash,
        p_model, p_kernel_version, p_baseband_version,
        p_fingerprint, COALESCE(NULLIF(p_extended_fingerprint, ''), p_fingerprint), now()
    )
    ON CONFLICT (fingerprint) DO UPDATE SET
        user_id             = COALESCE(EXCLUDED.user_id, public.device_identities.user_id),
        device_id           = EXCLUDED.device_id,
        mac_address         = EXCLUDED.mac_address,
        ip_address          = EXCLUDED.ip_address,
        ip_hash             = EXCLUDED.ip_hash,
        mac_hash            = EXCLUDED.mac_hash,
        model               = EXCLUDED.model,
        kernel_version      = EXCLUDED.kernel_version,
        baseband_version    = EXCLUDED.baseband_version,
        extended_fingerprint= EXCLUDED.extended_fingerprint,
        last_seen_at        = now()
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;

-- فحص الحظر: بيطابق البصمة الثابتة والبصمة الموسّعة (زي منطق التطبيق تماماً)
CREATE OR REPLACE FUNCTION public.is_device_banned(
    p_fingerprint TEXT,
    p_extended_fingerprint TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.banned_devices b
        WHERE (b.fingerprint = p_fingerprint
               OR (p_extended_fingerprint IS NOT NULL AND b.extended_fingerprint = p_extended_fingerprint)
               OR b.extended_fingerprint = p_fingerprint)
          AND (b.expires_at IS NULL OR b.expires_at > now())
    )
    OR EXISTS (
        SELECT 1 FROM public.banned_networks n
        WHERE n.fingerprint = p_fingerprint
          AND (n.expires_at IS NULL OR n.expires_at > now())
    );
$$;

GRANT EXECUTE ON FUNCTION public.is_device_banned(TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_device_identity(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.is_banned_now(UUID) TO anon, authenticated;


-- =============================================================================
-- 4) VIDEOS  (الفيديو على B2)
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.videos (
    id TEXT PRIMARY KEY DEFAULT gen_random_uuid()::TEXT,
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    description TEXT,

    video_url TEXT,                 -- الرابط العام على B2
    thumbnail_url TEXT,
    storage_type TEXT NOT NULL DEFAULT 'b2'
        CHECK (storage_type IN ('b2', 'supabase', 'demo')),
    b2_key TEXT,                    -- مفتاح الحذف/الإدارة في B2
    b2_bucket TEXT,
    mime_type TEXT,
    size_bytes BIGINT,
    duration DOUBLE PRECISION,
    width INTEGER,
    height INTEGER,
    is_vertical BOOLEAN NOT NULL DEFAULT FALSE,
    is_short BOOLEAN NOT NULL DEFAULT FALSE,

    views BIGINT NOT NULL DEFAULT 0,
    real_views BIGINT NOT NULL DEFAULT 0,
    likes BIGINT NOT NULL DEFAULT 0,
    comments_count BIGINT NOT NULL DEFAULT 0,

    status TEXT NOT NULL DEFAULT 'ready'
        CHECK (status IN ('processing', 'ready', 'failed')),
    ban_status TEXT NOT NULL DEFAULT 'none'
        CHECK (ban_status IN ('none', 'temporary', 'permanent', 'deleted')),
    ban_reason TEXT,
    temp_ban_until TIMESTAMPTZ,
    warning_reason TEXT,
    deleted BOOLEAN NOT NULL DEFAULT FALSE,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='videos' AND column_name='b2_key') THEN ALTER TABLE public.videos ADD COLUMN b2_key TEXT; END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='videos' AND column_name='b2_bucket') THEN ALTER TABLE public.videos ADD COLUMN b2_bucket TEXT; END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='videos' AND column_name='real_views') THEN ALTER TABLE public.videos ADD COLUMN real_views BIGINT NOT NULL DEFAULT 0; END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='videos' AND column_name='comments_count') THEN ALTER TABLE public.videos ADD COLUMN comments_count BIGINT NOT NULL DEFAULT 0; END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='videos' AND column_name='is_short') THEN ALTER TABLE public.videos ADD COLUMN is_short BOOLEAN NOT NULL DEFAULT FALSE; END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='videos' AND column_name='width') THEN ALTER TABLE public.videos ADD COLUMN width INTEGER; END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='videos' AND column_name='height') THEN ALTER TABLE public.videos ADD COLUMN height INTEGER; END IF;
END $$;

ALTER TABLE public.videos ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Videos are viewable by everyone" ON public.videos;
CREATE POLICY "Videos are viewable by everyone"
    ON public.videos FOR SELECT
    USING (
        (COALESCE(deleted, false) = false
         AND COALESCE(ban_status, 'none') NOT IN ('deleted', 'permanent')
         AND (temp_ban_until IS NULL OR temp_ban_until <= now()))
        OR auth.uid() = user_id
        OR public.is_admin()
    );

DROP POLICY IF EXISTS "Users can insert their own videos" ON public.videos;
CREATE POLICY "Users can insert their own videos"
    ON public.videos FOR INSERT WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can update their own videos" ON public.videos;
CREATE POLICY "Users can update their own videos"
    ON public.videos FOR UPDATE
    USING (auth.uid() = user_id OR public.is_admin())
    WITH CHECK (auth.uid() = user_id OR public.is_admin());

DROP POLICY IF EXISTS "Users can delete their own videos" ON public.videos;
CREATE POLICY "Users can delete their own videos"
    ON public.videos FOR DELETE
    USING (auth.uid() = user_id OR public.is_admin());

DROP TRIGGER IF EXISTS trg_videos_touch ON public.videos;
CREATE TRIGGER trg_videos_touch
    BEFORE UPDATE ON public.videos
    FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();


-- =============================================================================
-- 5) VIEWS / LIKES / SAVES / FOLLOWS / COMMENTS
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.video_views (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    video_id TEXT REFERENCES public.videos(id) ON DELETE CASCADE,
    user_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    viewer_fingerprint TEXT,
    viewer_extended_fingerprint TEXT,
    ip_hash TEXT,
    watched_duration INTEGER NOT NULL DEFAULT 0,
    total_duration INTEGER,
    watch_percent INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS video_views_video_idx ON public.video_views(video_id, created_at DESC);
CREATE INDEX IF NOT EXISTS video_views_user_idx ON public.video_views(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS video_views_fingerprint_idx ON public.video_views(viewer_fingerprint, created_at DESC);

ALTER TABLE public.video_views ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Anyone can insert a view" ON public.video_views;
CREATE POLICY "Anyone can insert a view"
    ON public.video_views FOR INSERT WITH CHECK (true);
DROP POLICY IF EXISTS "Admins can view all views" ON public.video_views;
CREATE POLICY "Admins can view all views"
    ON public.video_views FOR SELECT USING (public.is_admin());

CREATE TABLE IF NOT EXISTS public.likes (
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE NOT NULL,
    video_id TEXT REFERENCES public.videos(id) ON DELETE CASCADE NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, video_id)
);
CREATE INDEX IF NOT EXISTS likes_video_idx ON public.likes(video_id);
ALTER TABLE public.likes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Likes are viewable by everyone" ON public.likes;
CREATE POLICY "Likes are viewable by everyone" ON public.likes FOR SELECT USING (true);
DROP POLICY IF EXISTS "Users manage their own likes" ON public.likes;
CREATE POLICY "Users manage their own likes" ON public.likes FOR ALL USING (auth.uid() = user_id);

CREATE TABLE IF NOT EXISTS public.saved_videos (
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE NOT NULL,
    video_id TEXT REFERENCES public.videos(id) ON DELETE CASCADE NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, video_id)
);
CREATE INDEX IF NOT EXISTS saved_videos_user_idx ON public.saved_videos(user_id, created_at DESC);
ALTER TABLE public.saved_videos ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users manage their own saved videos" ON public.saved_videos;
CREATE POLICY "Users manage their own saved videos" ON public.saved_videos FOR ALL USING (auth.uid() = user_id);

CREATE TABLE IF NOT EXISTS public.subscriptions (
    subscriber_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE NOT NULL,
    channel_owner_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (subscriber_id, channel_owner_id),
    CHECK (subscriber_id <> channel_owner_id)
);
ALTER TABLE public.subscriptions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Subscriptions are viewable by everyone" ON public.subscriptions;
CREATE POLICY "Subscriptions are viewable by everyone" ON public.subscriptions FOR SELECT USING (true);
DROP POLICY IF EXISTS "Users manage their own subscriptions" ON public.subscriptions;
CREATE POLICY "Users manage their own subscriptions" ON public.subscriptions FOR ALL USING (auth.uid() = subscriber_id);

CREATE TABLE IF NOT EXISTS public.comments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    video_id TEXT REFERENCES public.videos(id) ON DELETE CASCADE,
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE NOT NULL,
    content TEXT NOT NULL,
    likes BIGINT NOT NULL DEFAULT 0,
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS comments_video_idx ON public.comments(video_id, created_at DESC);
CREATE INDEX IF NOT EXISTS comments_user_video_idx ON public.comments(user_id, video_id);
ALTER TABLE public.comments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Comments are viewable by everyone" ON public.comments;
CREATE POLICY "Comments are viewable by everyone" ON public.comments FOR SELECT USING (is_deleted = false);
DROP POLICY IF EXISTS "Users can insert their own comments" ON public.comments;
CREATE POLICY "Users can insert their own comments" ON public.comments FOR INSERT WITH CHECK (auth.uid() = user_id);
DROP POLICY IF EXISTS "Users can update their own comments" ON public.comments;
CREATE POLICY "Users can update their own comments" ON public.comments FOR UPDATE USING (auth.uid() = user_id);
DROP POLICY IF EXISTS "Users can delete their own comments" ON public.comments;
CREATE POLICY "Users can delete their own comments" ON public.comments FOR DELETE USING (auth.uid() = user_id OR public.is_admin());
DROP TRIGGER IF EXISTS trg_comments_touch ON public.comments;
CREATE TRIGGER trg_comments_touch BEFORE UPDATE ON public.comments FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE TABLE IF NOT EXISTS public.comment_likes (
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE NOT NULL,
    comment_id UUID REFERENCES public.comments(id) ON DELETE CASCADE NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, comment_id)
);
ALTER TABLE public.comment_likes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Comment likes are viewable by everyone" ON public.comment_likes;
CREATE POLICY "Comment likes are viewable by everyone" ON public.comment_likes FOR SELECT USING (true);
DROP POLICY IF EXISTS "Users manage their own comment likes" ON public.comment_likes;
CREATE POLICY "Users manage their own comment likes" ON public.comment_likes FOR ALL USING (auth.uid() = user_id);

-- عدّادات حقيقية بالتريجر
CREATE OR REPLACE FUNCTION public.update_video_likes_count()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        UPDATE public.videos SET likes = GREATEST(COALESCE(likes,0) + 1, 0) WHERE id = NEW.video_id;
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        UPDATE public.videos SET likes = GREATEST(COALESCE(likes,0) - 1, 0) WHERE id = OLD.video_id;
        RETURN OLD;
    END IF;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_video_likes_insert ON public.likes;
CREATE TRIGGER trg_video_likes_insert AFTER INSERT ON public.likes FOR EACH ROW EXECUTE FUNCTION public.update_video_likes_count();
DROP TRIGGER IF EXISTS trg_video_likes_delete ON public.likes;
CREATE TRIGGER trg_video_likes_delete AFTER DELETE ON public.likes FOR EACH ROW EXECUTE FUNCTION public.update_video_likes_count();

CREATE OR REPLACE FUNCTION public.update_comments_count()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        UPDATE public.videos SET comments_count = GREATEST(COALESCE(comments_count,0) + 1, 0) WHERE id = NEW.video_id;
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        UPDATE public.videos SET comments_count = GREATEST(COALESCE(comments_count,0) - 1, 0) WHERE id = OLD.video_id;
        RETURN OLD;
    ELSIF TG_OP = 'UPDATE' AND OLD.is_deleted IS DISTINCT FROM NEW.is_deleted THEN
        UPDATE public.videos
        SET comments_count = GREATEST(COALESCE(comments_count,0) + CASE WHEN NEW.is_deleted THEN -1 ELSE 1 END, 0)
        WHERE id = NEW.video_id;
        RETURN NEW;
    END IF;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_comments_count_ins ON public.comments;
CREATE TRIGGER trg_comments_count_ins AFTER INSERT ON public.comments FOR EACH ROW EXECUTE FUNCTION public.update_comments_count();
DROP TRIGGER IF EXISTS trg_comments_count_del ON public.comments;
CREATE TRIGGER trg_comments_count_del AFTER DELETE ON public.comments FOR EACH ROW EXECUTE FUNCTION public.update_comments_count();
DROP TRIGGER IF EXISTS trg_comments_count_upd ON public.comments;
CREATE TRIGGER trg_comments_count_upd AFTER UPDATE OF is_deleted ON public.comments FOR EACH ROW EXECUTE FUNCTION public.update_comments_count();

CREATE OR REPLACE FUNCTION public.update_follow_counts()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        UPDATE public.profiles SET following_count = GREATEST(COALESCE(following_count,0)+1,0) WHERE id = NEW.subscriber_id;
        UPDATE public.profiles SET followers_count  = GREATEST(COALESCE(followers_count,0)+1,0)  WHERE id = NEW.channel_owner_id;
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        UPDATE public.profiles SET following_count = GREATEST(COALESCE(following_count,0)-1,0) WHERE id = OLD.subscriber_id;
        UPDATE public.profiles SET followers_count  = GREATEST(COALESCE(followers_count,0)-1,0)  WHERE id = OLD.channel_owner_id;
        RETURN OLD;
    END IF;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_follows_ins ON public.subscriptions;
CREATE TRIGGER trg_follows_ins AFTER INSERT ON public.subscriptions FOR EACH ROW EXECUTE FUNCTION public.update_follow_counts();
DROP TRIGGER IF EXISTS trg_follows_del ON public.subscriptions;
CREATE TRIGGER trg_follows_del AFTER DELETE ON public.subscriptions FOR EACH ROW EXECUTE FUNCTION public.update_follow_counts();


-- =============================================================================
-- 6) SOCIAL POSTS (المنشورات / Home)
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.social_posts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    content TEXT,
    media_type TEXT NOT NULL DEFAULT 'none' CHECK (media_type IN ('image', 'video', 'none')),
    media_url TEXT,
    thumbnail_url TEXT,
    video_id TEXT REFERENCES public.videos(id) ON DELETE SET NULL,
    is_sync_to_home BOOLEAN NOT NULL DEFAULT TRUE,
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    pinned BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.social_posts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Public posts" ON public.social_posts;
CREATE POLICY "Public posts" ON public.social_posts FOR SELECT USING (is_deleted = false);
DROP POLICY IF EXISTS "User posts" ON public.social_posts;
CREATE POLICY "User posts" ON public.social_posts FOR INSERT WITH CHECK (auth.uid() = user_id);
DROP POLICY IF EXISTS "User update posts" ON public.social_posts;
CREATE POLICY "User update posts" ON public.social_posts FOR UPDATE USING (auth.uid() = user_id OR public.is_admin());
DROP POLICY IF EXISTS "Admins manage posts" ON public.social_posts;
CREATE POLICY "Admins manage posts" ON public.social_posts FOR DELETE USING (public.is_admin());
DROP TRIGGER IF EXISTS trg_social_posts_touch ON public.social_posts;
CREATE TRIGGER trg_social_posts_touch BEFORE UPDATE ON public.social_posts FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE TABLE IF NOT EXISTS public.post_likes (
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE NOT NULL,
    post_id UUID REFERENCES public.social_posts(id) ON DELETE CASCADE NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, post_id)
);
ALTER TABLE public.post_likes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Post likes are viewable by everyone" ON public.post_likes;
CREATE POLICY "Post likes are viewable by everyone" ON public.post_likes FOR SELECT USING (true);
DROP POLICY IF EXISTS "Users manage their own post likes" ON public.post_likes;
CREATE POLICY "Users manage their own post likes" ON public.post_likes FOR ALL USING (auth.uid() = user_id);

CREATE TABLE IF NOT EXISTS public.post_comments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    post_id UUID REFERENCES public.social_posts(id) ON DELETE CASCADE NOT NULL,
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE NOT NULL,
    content TEXT NOT NULL,
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS post_comments_post_idx ON public.post_comments(post_id, created_at DESC);
ALTER TABLE public.post_comments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Post comments are viewable by everyone" ON public.post_comments;
CREATE POLICY "Post comments are viewable by everyone" ON public.post_comments FOR SELECT USING (is_deleted = false);
DROP POLICY IF EXISTS "Users can insert their own post comments" ON public.post_comments;
CREATE POLICY "Users can insert their own post comments" ON public.post_comments FOR INSERT WITH CHECK (auth.uid() = user_id);
DROP POLICY IF EXISTS "Users can delete their own post comments" ON public.post_comments;
CREATE POLICY "Users can delete their own post comments" ON public.post_comments FOR DELETE USING (auth.uid() = user_id OR public.is_admin());

CREATE OR REPLACE VIEW public.social_feed AS
SELECT
    p.id,
    p.user_id,
    p.content,
    p.media_type,
    p.media_url,
    p.thumbnail_url,
    p.video_id,
    p.is_sync_to_home,
    p.pinned,
    p.created_at,
    pr.full_name,
    pr.avatar_url,
    pr.verified,
    pr.is_admin AS author_is_admin,
    v.is_vertical AS video_is_vertical,
    (SELECT count(*) FROM public.post_likes l WHERE l.post_id = p.id)::BIGINT AS likes_count,
    (SELECT count(*) FROM public.post_comments c WHERE c.post_id = p.id AND c.is_deleted = false)::BIGINT AS comments_count,
    EXISTS (SELECT 1 FROM public.post_likes l WHERE l.post_id = p.id AND l.user_id = auth.uid()) AS user_has_liked
FROM public.social_posts p
LEFT JOIN public.profiles pr ON p.user_id = pr.id
LEFT JOIN public.videos v ON p.video_id = v.id
WHERE p.is_deleted = false
ORDER BY p.pinned DESC, p.created_at DESC;

GRANT SELECT ON public.social_feed TO anon, authenticated;


-- =============================================================================
-- 7) REPORTS / SUGGESTIONS  (الضيوف يقدروا يستخدموهم)
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.reports (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    reporter_user_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    reporter_fingerprint TEXT,
    target_type TEXT NOT NULL CHECK (target_type IN ('video', 'post', 'comment', 'user')),
    target_id TEXT NOT NULL,
    reason TEXT NOT NULL,
    details TEXT,
    status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'reviewed', 'resolved', 'dismissed')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.reports ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Anyone can submit a report" ON public.reports;
CREATE POLICY "Anyone can submit a report" ON public.reports FOR INSERT WITH CHECK (true);
DROP POLICY IF EXISTS "Admins manage reports" ON public.reports;
CREATE POLICY "Admins manage reports" ON public.reports FOR ALL USING (public.is_admin());

CREATE TABLE IF NOT EXISTS public.suggestions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    fingerprint TEXT,
    content TEXT NOT NULL,
    contact TEXT,
    status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'reviewed', 'resolved')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.suggestions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Anyone can submit a suggestion" ON public.suggestions;
CREATE POLICY "Anyone can submit a suggestion" ON public.suggestions FOR INSERT WITH CHECK (true);
DROP POLICY IF EXISTS "Anyone can view suggestions" ON public.suggestions;
CREATE POLICY "Anyone can view suggestions" ON public.suggestions FOR SELECT USING (true);
DROP POLICY IF EXISTS "Admins manage suggestions" ON public.suggestions;
CREATE POLICY "Admins manage suggestions" ON public.suggestions FOR ALL USING (public.is_admin());


-- =============================================================================
-- 8) BANNERS
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.banners (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title TEXT,
    image_url TEXT NOT NULL,
    link_url TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    starts_at TIMESTAMPTZ,
    ends_at TIMESTAMPTZ,
    sort_order INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.banners ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Public can view active banners" ON public.banners;
CREATE POLICY "Public can view active banners"
    ON public.banners FOR SELECT
    USING (is_active AND (starts_at IS NULL OR starts_at <= now()) AND (ends_at IS NULL OR ends_at >= now()));
DROP POLICY IF EXISTS "Admins manage banners" ON public.banners;
CREATE POLICY "Admins manage banners" ON public.banners FOR ALL USING (public.is_admin());


-- =============================================================================
-- 9) PRO CODES / DAILY LIMITS
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.subscription_codes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code TEXT NOT NULL UNIQUE,
    created_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    duration_minutes INTEGER NOT NULL DEFAULT 1440,
    used_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    used_at TIMESTAMPTZ,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    max_uses INTEGER NOT NULL DEFAULT 1,
    use_count INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.subscription_codes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admin manage codes" ON public.subscription_codes;
CREATE POLICY "Admin manage codes" ON public.subscription_codes FOR ALL USING (public.is_admin());
DROP POLICY IF EXISTS "Authenticated users can check active codes" ON public.subscription_codes;
CREATE POLICY "Authenticated users can check active codes"
    ON public.subscription_codes FOR SELECT TO authenticated USING (is_active = true);

CREATE TABLE IF NOT EXISTS public.daily_upload_counts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    upload_date DATE NOT NULL DEFAULT CURRENT_DATE,
    wide_count INTEGER NOT NULL DEFAULT 0,
    short_count INTEGER NOT NULL DEFAULT 0,
    post_count INTEGER NOT NULL DEFAULT 0,
    videos_in_posts INTEGER NOT NULL DEFAULT 0,
    UNIQUE (user_id, upload_date)
);
ALTER TABLE public.daily_upload_counts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users manage own counts" ON public.daily_upload_counts;
CREATE POLICY "Users manage own counts" ON public.daily_upload_counts FOR ALL USING (auth.uid() = user_id);
DROP POLICY IF EXISTS "Admins view all counts" ON public.daily_upload_counts;
CREATE POLICY "Admins view all counts" ON public.daily_upload_counts FOR SELECT USING (public.is_admin());


-- =============================================================================
-- 10) B2 STORAGE USAGE + UPLOAD SESSIONS
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.storage_usage (
    bucket TEXT PRIMARY KEY,
    used_bytes BIGINT NOT NULL DEFAULT 0,
    limit_bytes BIGINT NOT NULL DEFAULT 10737418240, -- 10 GiB = B2 free
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
INSERT INTO public.storage_usage(bucket, limit_bytes)
VALUES ('clips-videos', 10737418240)
ON CONFLICT (bucket) DO NOTHING;

ALTER TABLE public.storage_usage ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.storage_usage FROM anon, authenticated;
GRANT ALL ON public.storage_usage TO service_role;
DROP POLICY IF EXISTS "Admins view storage usage" ON public.storage_usage;
CREATE POLICY "Admins view storage usage" ON public.storage_usage FOR SELECT USING (public.is_admin());

CREATE TABLE IF NOT EXISTS public.b2_upload_sessions (
    session_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    -- NULL is allowed for local/Firebase sessions; only Supabase Auth users are UUIDs.
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
    b2_key TEXT UNIQUE,
    expected_size BIGINT NOT NULL CHECK (expected_size > 0),
    upload_type TEXT NOT NULL DEFAULT 'short' CHECK (upload_type IN ('wide', 'short', 'post', 'video_in_post')),
    status TEXT NOT NULL DEFAULT 'reserved'
        CHECK (status IN ('reserved', 'initialized', 'uploaded', 'processing', 'ready', 'failed')),
    video_id TEXT UNIQUE,
    playback_url TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL DEFAULT (now() + INTERVAL '24 hours')
);
-- Existing installations already created this column as NOT NULL.
ALTER TABLE public.b2_upload_sessions ALTER COLUMN user_id DROP NOT NULL;
CREATE INDEX IF NOT EXISTS b2_sessions_user_expiry_idx ON public.b2_upload_sessions(user_id, expires_at);

ALTER TABLE public.b2_upload_sessions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.b2_upload_sessions FROM anon, authenticated;
GRANT ALL ON public.b2_upload_sessions TO service_role;


-- =============================================================================
-- 11) ADMIN LOG
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.admin_actions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    admin_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    target_user_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    target_video_id TEXT,
    target_post_id UUID REFERENCES public.social_posts(id) ON DELETE SET NULL,
    action TEXT NOT NULL,
    reason TEXT,
    meta JSONB,
    duration_minutes INTEGER,
    is_visible_to_public BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.admin_actions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins manage actions" ON public.admin_actions;
CREATE POLICY "Admins manage actions" ON public.admin_actions FOR ALL USING (public.is_admin());
DROP POLICY IF EXISTS "Public can view visible admin actions" ON public.admin_actions;
CREATE POLICY "Public can view visible admin actions"
    ON public.admin_actions FOR SELECT USING (is_visible_to_public = true);


-- =============================================================================
-- 12) TRIGGER: NEW USER
-- =============================================================================
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    INSERT INTO public.profiles (id, full_name, avatar_url, is_admin)
    VALUES (
        NEW.id,
        COALESCE(NEW.raw_user_meta_data->>'full_name', NEW.raw_user_meta_data->>'name', NEW.email),
        NEW.raw_user_meta_data->>'avatar_url',
        CASE WHEN COALESCE(NEW.email,'') = 'probader671@gmail.com' THEN TRUE ELSE FALSE END
    )
    ON CONFLICT (id) DO NOTHING;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

INSERT INTO public.profiles (id, full_name, avatar_url, is_admin)
SELECT au.id,
       COALESCE(au.raw_user_meta_data->>'full_name', au.raw_user_meta_data->>'name', au.email),
       au.raw_user_meta_data->>'avatar_url',
       CASE WHEN COALESCE(au.email,'') = 'probader671@gmail.com' THEN TRUE ELSE FALSE END
FROM auth.users au
WHERE au.id NOT IN (SELECT id FROM public.profiles)
ON CONFLICT (id) DO NOTHING;

UPDATE public.profiles
SET is_admin = TRUE
WHERE id IN (SELECT id FROM auth.users WHERE email = 'probader671@gmail.com');


-- =============================================================================
-- 13) RPC: VIEWS
-- =============================================================================
CREATE OR REPLACE FUNCTION public.record_video_view(
    p_video_id TEXT,
    p_user_id UUID DEFAULT NULL,
    p_fingerprint TEXT DEFAULT NULL,
    p_extended_fingerprint TEXT DEFAULT NULL,
    p_ip_hash TEXT DEFAULT NULL,
    p_watched_duration INTEGER DEFAULT 0,
    p_total_duration INTEGER DEFAULT 0
)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_percent INTEGER;
    v_existing UUID;
BEGIN
    IF p_total_duration > 0 THEN
        v_percent := LEAST(100, GREATEST(0, (p_watched_duration * 100) / p_total_duration));
    ELSE
        v_percent := 0;
    END IF;

    SELECT id INTO v_existing
    FROM public.video_views
    WHERE video_id = p_video_id
      AND (
            (p_user_id IS NOT NULL AND user_id = p_user_id)
         OR (p_fingerprint IS NOT NULL AND viewer_fingerprint = p_fingerprint)
         OR (p_ip_hash IS NOT NULL AND ip_hash = p_ip_hash)
      )
      AND created_at > now() - INTERVAL '24 hours'
    ORDER BY created_at DESC
    LIMIT 1;

    IF v_existing IS NOT NULL THEN
        UPDATE public.video_views
        SET watched_duration = GREATEST(watched_duration, p_watched_duration),
            watch_percent = GREATEST(watch_percent, v_percent)
        WHERE id = v_existing;
        RETURN FALSE;
    END IF;

    INSERT INTO public.video_views (
        video_id, user_id, viewer_fingerprint, viewer_extended_fingerprint,
        ip_hash, watched_duration, total_duration, watch_percent
    )
    VALUES (
        p_video_id, p_user_id, p_fingerprint, p_extended_fingerprint,
        p_ip_hash, p_watched_duration, p_total_duration, v_percent
    );

    UPDATE public.videos
    SET views = GREATEST(COALESCE(views,0) + 1, 0),
        real_views = GREATEST(COALESCE(real_views,0) + 1, 0)
    WHERE id = p_video_id;

    RETURN TRUE;
END;
$$;

CREATE OR REPLACE FUNCTION public.increment_views(video_id_param TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    UPDATE public.videos SET views = GREATEST(COALESCE(views,0)+1,0) WHERE id = video_id_param;
END;
$$;

-- دفعة مشاهدات: التطبيق يخزن محلياً ويرسل دفعة واحدة
CREATE OR REPLACE FUNCTION public.register_views_batch(p_views JSONB)
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_row JSONB;
    v_count INTEGER := 0;
BEGIN
    IF p_views IS NULL OR jsonb_typeof(p_views) <> 'array' THEN
        RETURN 0;
    END IF;

    FOR v_row IN SELECT value FROM jsonb_array_elements(p_views)
    LOOP
        -- صف ناقص /= يفشّل الدفعة كلها
        IF COALESCE(v_row->>'video_id', '') = '' THEN CONTINUE; END IF;

        IF public.record_video_view(
            v_row->>'video_id',
            NULLIF(v_row->>'user_id','')::UUID,
            v_row->>'fingerprint',
            v_row->>'extended_fingerprint',
            v_row->>'ip_hash',
            COALESCE((v_row->>'watched_duration')::INTEGER, 0),
            COALESCE((v_row->>'total_duration')::INTEGER, 0)
        ) THEN
            v_count := v_count + 1;
        END IF;
    END LOOP;

    RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.record_video_view(TEXT, UUID, TEXT, TEXT, TEXT, INTEGER, INTEGER) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.register_views_batch(JSONB) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.increment_views(TEXT) TO anon, authenticated;


-- =============================================================================
-- 14) RPC: UPLOAD LIMITS + B2 SESSIONS
-- =============================================================================
CREATE OR REPLACE FUNCTION public.check_upload_limit(
    p_user_id UUID,
    p_type TEXT,
    p_file_size BIGINT DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_is_pro BOOLEAN := FALSE;
    v_pro_expiry TIMESTAMPTZ;
    v_max_wide INTEGER := 2;
    v_max_short INTEGER := 3;
    v_max_post INTEGER := 3;
    v_max_size BIGINT := 26214400;  -- 25 MiB للمستخدم العادي
    v_wide_count INTEGER := 0;
    v_short_count INTEGER := 0;
    v_post_count INTEGER := 0;
    v_videos_in_posts INTEGER := 0;
BEGIN
    IF COALESCE(public.is_banned_now(p_user_id), false) THEN
        RETURN jsonb_build_object('allowed', false, 'reason', 'الحساب محظور');
    END IF;

    SELECT is_pro, pro_expires_at INTO v_is_pro, v_pro_expiry
    FROM public.profiles WHERE id = p_user_id;

    IF v_is_pro AND v_pro_expiry IS NOT NULL AND v_pro_expiry < now() THEN
        UPDATE public.profiles SET is_pro = FALSE, pro_expires_at = NULL WHERE id = p_user_id;
        v_is_pro := FALSE;
    END IF;

    IF v_is_pro THEN
        v_max_wide := 3;
        v_max_short := 5;
        v_max_size := 52428800;     -- 50 MiB للبرو
    END IF;

    IF p_file_size > v_max_size THEN
        RETURN jsonb_build_object(
            'allowed', false,
            'reason', 'حجم الملف يتجاوز الحد المسموح (' || (v_max_size / 1048576) || ' ميجا)'
        );
    END IF;

    INSERT INTO public.daily_upload_counts (user_id, upload_date)
    VALUES (p_user_id, CURRENT_DATE)
    ON CONFLICT (user_id, upload_date) DO NOTHING;

    SELECT wide_count, short_count, post_count, videos_in_posts
    INTO v_wide_count, v_short_count, v_post_count, v_videos_in_posts
    FROM public.daily_upload_counts
    WHERE user_id = p_user_id AND upload_date = CURRENT_DATE;

    IF p_type = 'wide' AND v_wide_count >= v_max_wide THEN
        RETURN jsonb_build_object('allowed', false, 'reason', 'تجاوزت الحد اليومي للفيديوهات العريضة (' || v_max_wide || ')');
    END IF;
    IF p_type = 'short' AND v_short_count >= v_max_short THEN
        RETURN jsonb_build_object('allowed', false, 'reason', 'تجاوزت الحد اليومي للشورتس (' || v_max_short || ')');
    END IF;
    IF p_type = 'post' AND NOT v_is_pro AND v_post_count >= v_max_post THEN
        RETURN jsonb_build_object('allowed', false, 'reason', 'تجاوزت الحد اليومي للمنشورات (' || v_max_post || ')');
    END IF;
    IF p_type = 'post' AND v_is_pro AND (v_post_count - LEAST(v_videos_in_posts, 1)) >= v_max_post THEN
        RETURN jsonb_build_object('allowed', false, 'reason', 'تجاوزت الحد اليومي للمنشورات (' || v_max_post || ')');
    END IF;

    IF p_type = 'wide' THEN
        UPDATE public.daily_upload_counts SET wide_count = wide_count + 1 WHERE user_id = p_user_id AND upload_date = CURRENT_DATE;
    ELSIF p_type = 'short' THEN
        UPDATE public.daily_upload_counts SET short_count = short_count + 1 WHERE user_id = p_user_id AND upload_date = CURRENT_DATE;
    ELSIF p_type = 'post' THEN
        UPDATE public.daily_upload_counts SET post_count = post_count + 1 WHERE user_id = p_user_id AND upload_date = CURRENT_DATE;
    ELSIF p_type = 'video_in_post' THEN
        UPDATE public.daily_upload_counts SET videos_in_posts = videos_in_posts + 1 WHERE user_id = p_user_id AND upload_date = CURRENT_DATE;
    END IF;

    RETURN jsonb_build_object(
        'allowed', true,
        'is_pro', v_is_pro,
        'max_size', v_max_size,
        'limits', jsonb_build_object(
            'wide_remaining', v_max_wide - v_wide_count,
            'short_remaining', v_max_short - v_short_count,
            'post_remaining', v_max_post - v_post_count
        )
    );
END;
$$;

-- حجز جلسة رفع B2 (للـ Edge Function بس - service_role)
CREATE OR REPLACE FUNCTION public.reserve_b2_upload_session(
    -- Defaults on every parameter keep the existing (uuid,bigint,text,text)
    -- signature while allowing local/Firebase sessions to omit the user id.
    p_user_id UUID DEFAULT NULL,
    p_expected_size BIGINT DEFAULT 0,
    p_b2_key TEXT DEFAULT NULL,
    p_upload_type TEXT DEFAULT 'short'
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_limit RECORD;
    v_active INTEGER := 0;
    v_recent INTEGER := 0;
    v_session_id UUID;
    v_check JSONB;
BEGIN
    IF auth.role() <> 'service_role' THEN
        RAISE EXCEPTION 'service role required' USING ERRCODE = '42501';
    END IF;

    IF p_expected_size IS NULL OR p_expected_size <= 0 THEN
        RAISE EXCEPTION 'invalid_file_size' USING ERRCODE = '22023';
    END IF;

    IF p_upload_type NOT IN ('wide', 'short', 'post', 'video_in_post') THEN
        RAISE EXCEPTION 'invalid_upload_type' USING ERRCODE = '22023';
    END IF;

    -- Anonymous/local sessions are grouped under one lock; real users keep
    -- their own lock so per-user limits stay race-free.
    PERFORM pg_advisory_xact_lock(hashtext(COALESCE(p_user_id::TEXT, 'anon')), 0);

    IF p_user_id IS NULL THEN
        -- No profile/daily-limit row exists for a local account. Enforce only
        -- the same hard 50 MiB ceiling so the 10 GiB B2 quota cannot be abused.
        IF p_expected_size > 52428800 THEN
            RAISE EXCEPTION 'upload_not_allowed: حجم الملف يتجاوز 50 ميجا' USING ERRCODE = '22023';
        END IF;
    ELSE
        v_check := public.check_upload_limit(p_user_id, p_upload_type, p_expected_size);
        IF COALESCE(v_check->>'allowed', 'false') <> 'true' THEN
            RAISE EXCEPTION 'upload_not_allowed: %', v_check->>'reason' USING ERRCODE = '22023';
        END IF;
    END IF;

    SELECT * INTO v_limit FROM public.storage_usage WHERE bucket = 'clips-videos';

    IF COALESCE(v_limit.used_bytes,0) + p_expected_size
       + COALESCE((SELECT SUM(expected_size) FROM public.b2_upload_sessions
                   WHERE status IN ('reserved','initialized','uploaded','processing')), 0)
       > COALESCE(v_limit.limit_bytes, 10737418240) - 536870912 THEN
        RAISE EXCEPTION 'global_storage_full' USING ERRCODE = '22023';
    END IF;

    IF p_user_id IS NOT NULL THEN
        DELETE FROM public.b2_upload_sessions
        WHERE user_id = p_user_id AND expires_at <= now();

        SELECT count(*)::INTEGER INTO v_active
        FROM public.b2_upload_sessions
        WHERE user_id = p_user_id
          AND status IN ('reserved','initialized','uploaded','processing')
          AND expires_at > now();
        IF v_active >= 3 THEN
            RAISE EXCEPTION 'upload_limit' USING ERRCODE = '22023';
        END IF;

        SELECT count(*)::INTEGER INTO v_recent
        FROM public.b2_upload_sessions
        WHERE user_id = p_user_id
          AND status IN ('uploaded','processing','ready')
          AND created_at >= now() - INTERVAL '24 hours';
        IF v_recent >= 5 THEN
            RAISE EXCEPTION 'daily_upload_limit' USING ERRCODE = '22023';
        END IF;
    END IF;

    INSERT INTO public.b2_upload_sessions (user_id, b2_key, expected_size, upload_type, status)
    VALUES (p_user_id, p_b2_key, p_expected_size, p_upload_type, 'reserved')
    RETURNING session_id INTO v_session_id;

    RETURN v_session_id;
END;
$$;

-- تحديث المساحة بعد نجاح الرفع
CREATE OR REPLACE FUNCTION public.finalize_b2_upload_session(
    p_session_id UUID,
    p_video_id TEXT,
    p_playback_url TEXT,
    p_size_bytes BIGINT
)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF auth.role() <> 'service_role' THEN
        RAISE EXCEPTION 'service role required' USING ERRCODE = '42501';
    END IF;

    UPDATE public.b2_upload_sessions
    SET status = 'ready', video_id = p_video_id, playback_url = p_playback_url
    WHERE session_id = p_session_id AND status <> 'ready';

    IF NOT FOUND THEN RETURN FALSE; END IF;

    UPDATE public.storage_usage
    SET used_bytes = GREATEST(used_bytes + p_size_bytes, 0), updated_at = now()
    WHERE bucket = 'clips-videos';

    RETURN TRUE;
END;
$$;

CREATE OR REPLACE FUNCTION public.cleanup_expired_upload_sessions()
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_deleted INTEGER;
BEGIN
    DELETE FROM public.b2_upload_sessions WHERE expires_at <= now();
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    RETURN v_deleted;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_storage_usage()
RETURNS JSONB
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT jsonb_build_object(
        'used_bytes', used_bytes,
        'limit_bytes', limit_bytes,
        'remaining_bytes', GREATEST(limit_bytes - used_bytes, 0)
    ) FROM public.storage_usage WHERE bucket = 'clips-videos';
$$;

REVOKE ALL ON FUNCTION public.reserve_b2_upload_session(UUID, BIGINT, TEXT, TEXT) FROM anon, authenticated;
REVOKE ALL ON FUNCTION public.finalize_b2_upload_session(UUID, TEXT, TEXT, BIGINT) FROM anon, authenticated;
REVOKE ALL ON FUNCTION public.cleanup_expired_upload_sessions() FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reserve_b2_upload_session(UUID, BIGINT, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.finalize_b2_upload_session(UUID, TEXT, TEXT, BIGINT) TO service_role;
GRANT EXECUTE ON FUNCTION public.cleanup_expired_upload_sessions() TO service_role;
GRANT EXECUTE ON FUNCTION public.get_storage_usage() TO authenticated;


-- =============================================================================
-- 15) RPC: PRO CODES
-- =============================================================================
CREATE OR REPLACE FUNCTION public.activate_pro_code(p_user_id UUID, p_code TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_code RECORD;
    v_expires TIMESTAMPTZ;
BEGIN
    SELECT * INTO v_code FROM public.subscription_codes
    WHERE code = upper(trim(p_code)) AND is_active = true
      AND (used_by IS NULL OR use_count < max_uses)
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'الكود غير صالح أو تم استخدامه');
    END IF;

    v_expires := now() + (v_code.duration_minutes || ' minutes')::INTERVAL;

    UPDATE public.subscription_codes
    SET used_by = p_user_id, used_at = now(), use_count = use_count + 1,
        is_active = (use_count + 1 < max_uses)
    WHERE id = v_code.id;

    UPDATE public.profiles
    SET is_pro = TRUE, pro_expires_at = v_expires, pro_activated_at = now()
    WHERE id = p_user_id;

    RETURN jsonb_build_object('success', true, 'expires_at', v_expires, 'duration_minutes', v_code.duration_minutes);
END;
$$;

CREATE OR REPLACE FUNCTION public.create_pro_code(
    p_code TEXT DEFAULT NULL,
    p_duration_minutes INTEGER DEFAULT 1440,
    p_max_uses INTEGER DEFAULT 1
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_final_code TEXT; v_new_id UUID;
BEGIN
    IF NOT public.is_admin() THEN
        RETURN jsonb_build_object('success', false, 'message', 'غير مصرح');
    END IF;

    IF p_code IS NULL THEN
        v_final_code := upper(substring(md5(random()::TEXT) FROM 1 FOR 8));
    ELSE
        v_final_code := upper(trim(p_code));
    END IF;

    INSERT INTO public.subscription_codes (code, created_by, duration_minutes, max_uses)
    VALUES (v_final_code, auth.uid(), p_duration_minutes, p_max_uses)
    RETURNING id INTO v_new_id;

    RETURN jsonb_build_object('success', true, 'code', v_final_code, 'id', v_new_id,
                              'duration_minutes', p_duration_minutes, 'max_uses', p_max_uses);
END;
$$;

CREATE OR REPLACE FUNCTION public.deactivate_pro_code(p_code_id UUID)
RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT public.is_admin() THEN RETURN FALSE; END IF;
    UPDATE public.subscription_codes SET is_active = FALSE WHERE id = p_code_id;
    RETURN TRUE;
END;
$$;

GRANT EXECUTE ON FUNCTION public.activate_pro_code(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_pro_code(TEXT, INTEGER, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.deactivate_pro_code(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_upload_limit(UUID, TEXT, BIGINT) TO authenticated;


-- =============================================================================
-- 16) RPC: ADMIN TOOLS
-- =============================================================================
CREATE OR REPLACE FUNCTION public.admin_warn_user(p_target UUID, p_reason TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT public.is_admin() THEN RETURN jsonb_build_object('success', false, 'message', 'غير مصرح'); END IF;
    UPDATE public.profiles
    SET warning_count = warning_count + 1, warning_reason = p_reason,
        warning_active = TRUE, warned_by = auth.uid()
    WHERE id = p_target;
    INSERT INTO public.admin_actions (admin_id, target_user_id, action, reason)
    VALUES (auth.uid(), p_target, 'warn', p_reason);
    RETURN jsonb_build_object('success', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_ban_user(p_target UUID, p_reason TEXT, p_days INTEGER DEFAULT 0)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_expiry TIMESTAMPTZ;
BEGIN
    IF NOT public.is_admin() THEN RETURN jsonb_build_object('success', false, 'message', 'غير مصرح'); END IF;
    IF p_days > 0 THEN v_expiry := now() + (p_days || ' days')::INTERVAL; END IF;

    UPDATE public.profiles
    SET is_banned = TRUE, banned = TRUE, ban_expires_at = v_expiry,
        ban_reason = p_reason, banned_by = auth.uid()
    WHERE id = p_target;

    INSERT INTO public.admin_actions (admin_id, target_user_id, action, reason, duration_minutes, meta)
    VALUES (auth.uid(), p_target,
            CASE WHEN p_days = 0 THEN 'ban_permanent' ELSE 'ban_temp' END,
            p_reason,
            CASE WHEN p_days > 0 THEN p_days * 24 * 60 ELSE NULL END,
            jsonb_build_object('expires_at', v_expiry, 'days', p_days));
    RETURN jsonb_build_object('success', true, 'expires_at', v_expiry);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_unban_user(p_target UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT public.is_admin() THEN RETURN jsonb_build_object('success', false, 'message', 'غير مصرح'); END IF;
    UPDATE public.profiles
    SET is_banned = FALSE, banned = FALSE, ban_expires_at = NULL, ban_reason = NULL
    WHERE id = p_target;
    INSERT INTO public.admin_actions (admin_id, target_user_id, action)
    VALUES (auth.uid(), p_target, 'unban');
    RETURN jsonb_build_object('success', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_toggle_verify(p_target UUID, p_verify BOOLEAN)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT public.is_admin() THEN RETURN jsonb_build_object('success', false, 'message', 'غير مصرح'); END IF;
    UPDATE public.profiles SET verified = p_verify WHERE id = p_target;
    INSERT INTO public.admin_actions (admin_id, target_user_id, action)
    VALUES (auth.uid(), p_target, CASE WHEN p_verify THEN 'verify' ELSE 'unverify' END);
    RETURN jsonb_build_object('success', true, 'verified', p_verify);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_ban_video(
    p_video_id TEXT, p_new_status TEXT, p_reason TEXT,
    p_until TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT public.is_admin() THEN RETURN jsonb_build_object('success', false, 'message', 'غير مصرح'); END IF;
    UPDATE public.videos
    SET ban_status = p_new_status, ban_reason = p_reason,
        temp_ban_until = p_until,
        deleted = CASE WHEN p_new_status = 'deleted' THEN TRUE ELSE deleted END
    WHERE id = p_video_id;
    IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'message', 'الفيديو غير موجود'); END IF;
    INSERT INTO public.admin_actions (admin_id, target_video_id, action, reason)
    VALUES (auth.uid(), p_video_id, 'ban_video_' || p_new_status, p_reason);
    RETURN jsonb_build_object('success', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_delete_video(p_video_id TEXT, p_reason TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT public.is_admin() THEN RETURN jsonb_build_object('success', false, 'message', 'غير مصرح'); END IF;
    UPDATE public.videos SET deleted = TRUE, ban_status = 'deleted', ban_reason = p_reason WHERE id = p_video_id;
    INSERT INTO public.admin_actions (admin_id, target_video_id, action, reason)
    VALUES (auth.uid(), p_video_id, 'delete_video', p_reason);
    RETURN jsonb_build_object('success', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_delete_post(p_post_id UUID, p_reason TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT public.is_admin() THEN RETURN jsonb_build_object('success', false, 'message', 'غير مصرح'); END IF;
    UPDATE public.social_posts SET is_deleted = TRUE WHERE id = p_post_id;
    INSERT INTO public.admin_actions (admin_id, target_post_id, action, reason)
    VALUES (auth.uid(), p_post_id, 'delete_post', p_reason);
    RETURN jsonb_build_object('success', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_pin_post(p_post_id UUID, p_pin BOOLEAN)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT public.is_admin() THEN RETURN jsonb_build_object('success', false, 'message', 'غير مصرح'); END IF;
    UPDATE public.social_posts SET pinned = p_pin WHERE id = p_post_id;
    INSERT INTO public.admin_actions (admin_id, target_post_id, action)
    VALUES (auth.uid(), p_post_id, CASE WHEN p_pin THEN 'pin_post' ELSE 'unpin_post' END);
    RETURN jsonb_build_object('success', true);
END;
$$;

-- حظر جهاز بالبصمتين (زي فحص التطبيق تماماً)
CREATE OR REPLACE FUNCTION public.admin_ban_device(
    p_fingerprint TEXT,
    p_extended_fingerprint TEXT DEFAULT NULL,
    p_reason TEXT DEFAULT NULL,
    p_days INTEGER DEFAULT 0
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_expiry TIMESTAMPTZ;
BEGIN
    IF NOT public.is_admin() THEN RETURN jsonb_build_object('success', false, 'message', 'غير مصرح'); END IF;
    IF p_days > 0 THEN v_expiry := now() + (p_days || ' days')::INTERVAL; END IF;

    INSERT INTO public.banned_devices (fingerprint, extended_fingerprint, reason, banned_by, expires_at)
    VALUES (
        p_fingerprint,
        CASE WHEN p_extended_fingerprint = p_fingerprint THEN NULL ELSE p_extended_fingerprint END,
        p_reason, auth.uid(), v_expiry
    )
    ON CONFLICT (fingerprint) DO UPDATE SET
        extended_fingerprint = EXCLUDED.extended_fingerprint,
        reason = EXCLUDED.reason, banned_by = auth.uid(), expires_at = EXCLUDED.expires_at;

    INSERT INTO public.admin_actions (admin_id, action, reason, meta)
    VALUES (auth.uid(), 'ban_device', p_reason,
            jsonb_build_object('fingerprint', p_fingerprint, 'extended', p_extended_fingerprint, 'days', p_days));
    RETURN jsonb_build_object('success', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_unban_device(
    p_fingerprint TEXT,
    p_extended_fingerprint TEXT DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT public.is_admin() THEN RETURN jsonb_build_object('success', false, 'message', 'غير مصرح'); END IF;
    DELETE FROM public.banned_devices
    WHERE fingerprint = p_fingerprint
       OR (p_extended_fingerprint IS NOT NULL AND extended_fingerprint = p_extended_fingerprint);
    INSERT INTO public.admin_actions (admin_id, action, meta)
    VALUES (auth.uid(), 'unban_device', jsonb_build_object('fingerprint', p_fingerprint));
    RETURN jsonb_build_object('success', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_ban_network(
    p_fingerprint TEXT,
    p_reason TEXT DEFAULT NULL,
    p_days INTEGER DEFAULT 0
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_expiry TIMESTAMPTZ;
BEGIN
    IF NOT public.is_admin() THEN RETURN jsonb_build_object('success', false, 'message', 'غير مصرح'); END IF;
    IF p_days > 0 THEN v_expiry := now() + (p_days || ' days')::INTERVAL; END IF;
    INSERT INTO public.banned_networks (fingerprint, reason, banned_by, expires_at)
    VALUES (p_fingerprint, p_reason, auth.uid(), v_expiry)
    ON CONFLICT (fingerprint) DO UPDATE SET reason = EXCLUDED.reason, expires_at = EXCLUDED.expires_at;
    INSERT INTO public.admin_actions (admin_id, action, reason, meta)
    VALUES (auth.uid(), 'ban_network', p_reason, jsonb_build_object('fingerprint', p_fingerprint));
    RETURN jsonb_build_object('success', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_warn_user(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_ban_user(UUID, TEXT, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_unban_user(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_toggle_verify(UUID, BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_ban_video(TEXT, TEXT, TEXT, TIMESTAMPTZ) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_video(TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_post(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_pin_post(UUID, BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_ban_device(TEXT, TEXT, TEXT, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_unban_device(TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_ban_network(TEXT, TEXT, INTEGER) TO authenticated;


-- =============================================================================
-- 17) RPC: USER STATUS
-- =============================================================================
CREATE OR REPLACE FUNCTION public.get_user_status(p_user_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_p RECORD;
    v_is_pro BOOLEAN;
    v_is_banned BOOLEAN;
    v_wide INTEGER := 0; v_short INTEGER := 0; v_post INTEGER := 0;
BEGIN
    SELECT * INTO v_p FROM public.profiles WHERE id = p_user_id;
    IF NOT FOUND THEN RETURN jsonb_build_object('found', false); END IF;

    v_is_pro := COALESCE(v_p.is_pro, false)
                AND (v_p.pro_expires_at IS NULL OR v_p.pro_expires_at > now());
    v_is_banned := COALESCE(public.is_banned_now(p_user_id), false);

    SELECT wide_count, short_count, post_count INTO v_wide, v_short, v_post
    FROM public.daily_upload_counts
    WHERE user_id = p_user_id AND upload_date = CURRENT_DATE;

    RETURN jsonb_build_object(
        'found', true,
        'is_admin', COALESCE(v_p.is_admin, false),
        'verified', COALESCE(v_p.verified, false),
        'is_pro', v_is_pro,
        'pro_expires_at', v_p.pro_expires_at,
        'is_banned', v_is_banned,
        'ban_expires_at', v_p.ban_expires_at,
        'warning_count', COALESCE(v_p.warning_count, 0),
        'theme_accent_argb', v_p.theme_accent_argb,
        'limits', jsonb_build_object(
            'wide_used', v_wide, 'wide_max', CASE WHEN v_is_pro THEN 3 ELSE 2 END,
            'short_used', v_short, 'short_max', CASE WHEN v_is_pro THEN 5 ELSE 3 END,
            'post_used', v_post, 'post_max', 3,
            'max_file_size', CASE WHEN v_is_pro THEN 52428800 ELSE 26214400 END
        )
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.get_user_comment_count(p_video_id UUID)
RETURNS INTEGER LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT count(*)::INTEGER FROM public.comments
    WHERE video_id = p_video_id::TEXT
      AND user_id = auth.uid()
      AND is_deleted = false;
$$;

GRANT EXECUTE ON FUNCTION public.get_user_status(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_comment_count(UUID) TO authenticated;


-- =============================================================================
-- 18) SUPABASE STORAGE FOR IMAGES ONLY (avatars / banners / media)
-- =============================================================================
INSERT INTO storage.buckets (id, name, public)
VALUES ('avatars', 'avatars', true), ('banners', 'banners', true), ('media', 'media', true)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "Public read images" ON storage.objects;
CREATE POLICY "Public read images" ON storage.objects FOR SELECT
USING (bucket_id IN ('avatars', 'banners', 'media'));

DROP POLICY IF EXISTS "Authenticated upload own image folder" ON storage.objects;
CREATE POLICY "Authenticated upload own image folder" ON storage.objects FOR INSERT
WITH CHECK (
    bucket_id IN ('avatars', 'banners', 'media')
    AND auth.role() = 'authenticated'
    AND (storage.foldername(name))[1] = auth.uid()::text
);

DROP POLICY IF EXISTS "Users update own image files" ON storage.objects;
CREATE POLICY "Users update own image files" ON storage.objects FOR UPDATE
USING (
    bucket_id IN ('avatars', 'banners', 'media')
    AND auth.uid() = owner
    AND (storage.foldername(name))[1] = auth.uid()::text
);

DROP POLICY IF EXISTS "Users delete own image files" ON storage.objects;
CREATE POLICY "Users delete own image files" ON storage.objects FOR DELETE
USING (
    bucket_id IN ('avatars', 'banners', 'media')
    AND auth.uid() = owner
    AND (storage.foldername(name))[1] = auth.uid()::text
);

DROP POLICY IF EXISTS "Admins delete any image file" ON storage.objects;
CREATE POLICY "Admins delete any image file" ON storage.objects FOR DELETE
USING (public.is_admin());


-- =============================================================================
-- 19) INDEXES NOT ALREADY CREATED + SCHEMA REFRESH
-- =============================================================================
CREATE INDEX IF NOT EXISTS videos_feed_idx ON public.videos(created_at DESC) WHERE COALESCE(deleted,false)=false;
CREATE INDEX IF NOT EXISTS videos_views_idx ON public.videos(views DESC) WHERE COALESCE(deleted,false)=false;
CREATE INDEX IF NOT EXISTS videos_user_idx ON public.videos(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS banned_devices_extended_idx ON public.banned_devices(extended_fingerprint);
CREATE INDEX IF NOT EXISTS banned_devices_expiry_idx ON public.banned_devices(expires_at);
CREATE INDEX IF NOT EXISTS reports_status_idx ON public.reports(status, created_at DESC);

-- =============================================================================
-- 20) EDGE FUNCTION PRIVILEGES (service_role)
-- Edge Functions authenticate to PostgREST with the secret service key. RLS is
-- bypassed by that role, but Postgres table/sequence/function privileges are
-- still required. Without this block inserts fail with 42501 permission denied.
-- =============================================================================
GRANT USAGE ON SCHEMA public TO service_role;
GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO service_role;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA public TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO service_role;

NOTIFY pgrst, 'reload schema';

-- =============================================================================
-- نهاية الملف
-- =============================================================================
