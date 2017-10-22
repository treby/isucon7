require 'mysql2'

class ImageMigrater
  def execute
    rows = db.query('SELECT name, data FROM image').to_a
    rows.each do |row|
      file_name = row['name']
      data = row['data']
      open("../public/icons/#{file_name}", 'wb') do |file|
        file.print(data)
      end
    end
  end

  private
  def db
    return @db_client if defined?(@db_client)

    @db_client = Mysql2::Client.new(
      host: ENV.fetch('ISUBATA_DB_HOST') { 'localhost' },
      port: ENV.fetch('ISUBATA_DB_PORT') { '3306' },
      username: ENV.fetch('ISUBATA_DB_USER') { 'root' },
      password: ENV.fetch('ISUBATA_DB_PASSWORD') { '' },
      database: 'isubata',
      encoding: 'utf8mb4'
    )
    @db_client.query('SET SESSION sql_mode=\'TRADITIONAL,NO_AUTO_VALUE_ON_ZERO,ONLY_FULL_GROUP_BY\'')
    @db_client
  end
end

ImageMigrater.new.execute
