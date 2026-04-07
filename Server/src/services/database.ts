// Database schema — only 3 tables, zero financial data
//
// CREATE TABLE users (
//   id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
//   email VARCHAR(255) UNIQUE NOT NULL,
//   password_hash VARCHAR(255) NOT NULL,
//   created_at TIMESTAMPTZ DEFAULT NOW()
// );
//
// CREATE TABLE plaid_items (
//   id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
//   user_id UUID REFERENCES users(id) ON DELETE CASCADE,
//   access_token_encrypted TEXT NOT NULL,
//   item_id VARCHAR(255) NOT NULL,
//   institution_name VARCHAR(255),
//   created_at TIMESTAMPTZ DEFAULT NOW()
// );
//
// CREATE TABLE device_tokens (
//   id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
//   user_id UUID REFERENCES users(id) ON DELETE CASCADE,
//   apns_token VARCHAR(255) NOT NULL,
//   platform VARCHAR(10) DEFAULT 'ios',
//   created_at TIMESTAMPTZ DEFAULT NOW()
// );

export async function initializeDatabase(): Promise<void> {
  // TODO: Initialize pg Pool and run migrations
  // const pool = new Pool({ connectionString: process.env.DATABASE_URL });
  console.log('Database initialization placeholder');
}
