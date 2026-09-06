\getenv app_password POSTGRES_APP_PASSWORD
CREATE ROLE website LOGIN PASSWORD :'app_password';
ALTER DATABASE website OWNER TO website;
\connect website
SET ROLE website;
CREATE TABLE "adsb_aircraft_sightings" (
	"id" serial PRIMARY KEY NOT NULL,
	"hex" varchar(6) NOT NULL,
	"flight" varchar(16),
	"category" varchar(4),
	"first_seen" timestamp with time zone,
	"last_seen" timestamp with time zone,
	"total_sightings" integer DEFAULT 0,
	"max_altitude" integer
);
--> statement-breakpoint
CREATE TABLE "adsb_rollups" (
	"id" serial PRIMARY KEY NOT NULL,
	"timestamp" timestamp with time zone NOT NULL,
	"unique_aircraft" integer,
	"total_aircraft" integer,
	"aircraft_with_position" integer,
	"max_altitude" integer,
	"total_messages" integer,
	"avg_rssi" real,
	"signal_db" real,
	"noise_db" real,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "chat_conversations" (
	"id" varchar(36) PRIMARY KEY NOT NULL,
	"anon_id" varchar(36) NOT NULL,
	"title" varchar(256),
	"model" varchar(128),
	"consent_given" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "chat_messages" (
	"id" serial PRIMARY KEY NOT NULL,
	"conversation_id" varchar(36) NOT NULL,
	"role" varchar(16) NOT NULL,
	"content" text NOT NULL,
	"thinking" text,
	"token_count" integer,
	"prompt_eval_count" integer,
	"eval_count" integer,
	"eval_duration" bigint,
	"prompt_eval_duration" bigint,
	"total_duration" bigint,
	"thinking_effort" varchar(16),
	"model" varchar(128),
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "page_sessions" (
	"id" varchar(36) PRIMARY KEY NOT NULL,
	"visitor_hash" varchar(64) NOT NULL,
	"started_at" timestamp with time zone DEFAULT now() NOT NULL,
	"last_seen_at" timestamp with time zone DEFAULT now() NOT NULL,
	"page_count" integer DEFAULT 1 NOT NULL,
	"entry_page" varchar(512),
	"exit_page" varchar(512),
	"referrer" varchar(1024),
	"country" varchar(8),
	"browser" varchar(64),
	"os" varchar(64),
	"bot_score" smallint DEFAULT 0 NOT NULL,
	"is_local_dev" boolean DEFAULT false NOT NULL,
	"duration" integer
);
--> statement-breakpoint
CREATE TABLE "page_views" (
	"id" serial PRIMARY KEY NOT NULL,
	"pathname" varchar(512) NOT NULL,
	"referrer" varchar(1024),
	"user_agent" text,
	"browser" varchar(64),
	"os" varchar(64),
	"visitor_hash" varchar(64) NOT NULL,
	"country" varchar(8),
	"session_id" varchar(36),
	"bot_score" smallint DEFAULT 0 NOT NULL,
	"is_local_dev" boolean DEFAULT false NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "chat_messages" ADD CONSTRAINT "chat_messages_conversation_id_chat_conversations_id_fk" FOREIGN KEY ("conversation_id") REFERENCES "public"."chat_conversations"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "idx_adsb_sightings_hex" ON "adsb_aircraft_sightings" USING btree ("hex");--> statement-breakpoint
CREATE INDEX "idx_adsb_sightings_last_seen" ON "adsb_aircraft_sightings" USING btree ("last_seen");--> statement-breakpoint
CREATE INDEX "idx_adsb_rollups_timestamp" ON "adsb_rollups" USING btree ("timestamp");--> statement-breakpoint
CREATE INDEX "idx_chat_conv_anon_id" ON "chat_conversations" USING btree ("anon_id");--> statement-breakpoint
CREATE INDEX "idx_chat_conv_updated_at" ON "chat_conversations" USING btree ("updated_at");--> statement-breakpoint
CREATE INDEX "idx_chat_msg_conv_id" ON "chat_messages" USING btree ("conversation_id");--> statement-breakpoint
CREATE INDEX "idx_chat_msg_created_at" ON "chat_messages" USING btree ("created_at");--> statement-breakpoint
CREATE INDEX "idx_page_sessions_visitor_hash" ON "page_sessions" USING btree ("visitor_hash");--> statement-breakpoint
CREATE INDEX "idx_page_sessions_started_at" ON "page_sessions" USING btree ("started_at");--> statement-breakpoint
CREATE INDEX "idx_page_sessions_last_seen_at" ON "page_sessions" USING btree ("last_seen_at");--> statement-breakpoint
CREATE INDEX "idx_page_sessions_is_local_dev" ON "page_sessions" USING btree ("is_local_dev");--> statement-breakpoint
CREATE INDEX "idx_page_views_created_at" ON "page_views" USING btree ("created_at");--> statement-breakpoint
CREATE INDEX "idx_page_views_pathname" ON "page_views" USING btree ("pathname");--> statement-breakpoint
CREATE INDEX "idx_page_views_visitor_hash" ON "page_views" USING btree ("visitor_hash");--> statement-breakpoint
CREATE INDEX "idx_page_views_session_id" ON "page_views" USING btree ("session_id");--> statement-breakpoint
CREATE INDEX "idx_page_views_is_local_dev" ON "page_views" USING btree ("is_local_dev");--> statement-breakpoint
CREATE INDEX "idx_page_views_bot_score" ON "page_views" USING btree ("bot_score");