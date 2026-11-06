CREATE TABLE leads (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email        text NOT NULL,
    name         text NOT NULL,
    company      text,
    job_title    text,
    company_size integer CHECK (company_size > 0),
    source       text NOT NULL,
    status       text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'scored')),
    score        smallint CHECK (score BETWEEN 0 AND 100),
    grade        text CHECK (grade IN ('hot', 'warm', 'cold')),
    is_duplicate boolean NOT NULL DEFAULT false,
    duplicate_of uuid REFERENCES leads (id),
    created_at   timestamptz NOT NULL DEFAULT clock_timestamp(),
    scored_at    timestamptz
);

-- Duplicate detection looks for the earliest lead with the same email.
CREATE INDEX leads_email_created_at_idx ON leads (email, created_at);

-- The worker's sweep looks for leads that never reached the queue.
CREATE INDEX leads_pending_created_at_idx ON leads (created_at) WHERE status = 'pending';
