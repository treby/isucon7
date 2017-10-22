require 'mysql2'

@db_client = Mysql2::Client.new(
  host: ENV.fetch('ISUBATA_DB_HOST') { 'localhost' },
  port: ENV.fetch('ISUBATA_DB_PORT') { '3306' },
  username: ENV.fetch('ISUBATA_DB_USER') { 'root' },
  password: ENV.fetch('ISUBATA_DB_PASSWORD') { '' },
  database: 'isubata',
  encoding: 'utf8mb4'
)

@db_client.query('ALTER TABLE message DROP INDEX index_on_message_channel_id_user_id')
@db_client.query('ALTER TABLE haveread DROP INDEX index_on_haveread_message_id')
