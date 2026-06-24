-- Truncate staging before populating to make it idempotent
TRUNCATE TABLE `${project_id}.${dataset_id}.staging_transactions`;

-- Populate staging table with static demo users and some random users
INSERT INTO `${project_id}.${dataset_id}.staging_transactions` (
  transaction_id,
  user_id,
  transaction_timestamp,
  amount,
  currency,
  user_email
)
VALUES
  (GENERATE_UUID(), 9999, CURRENT_TIMESTAMP(), 150.00, 'USD', 'shredded_user@example.com'),
  (GENERATE_UUID(), 9999, CURRENT_TIMESTAMP(), 45.50, 'USD', 'shredded_user@example.com'),
  (GENERATE_UUID(), 1111, CURRENT_TIMESTAMP(), 99.99, 'USD', 'active_user_1@example.com'),
  (GENERATE_UUID(), 2222, CURRENT_TIMESTAMP(), 12.00, 'USD', 'active_user_2@example.com');
