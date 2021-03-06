require 'digest/sha1'
require 'mysql2'
require 'sinatra/base'

class App < Sinatra::Base
  configure do
    set :session_secret, 'tonymoris'
    set :public_folder, File.expand_path('../../public', __FILE__)
    set :avatar_max_size, 1 * 1024 * 1024
    set :users_from_db, -> {
      return @_users_from_db if @_users_from_db
      db_client = Mysql2::Client.new(
        host: ENV.fetch('ISUBATA_DB_HOST') { 'localhost' },
        port: ENV.fetch('ISUBATA_DB_PORT') { '3306' },
        username: ENV.fetch('ISUBATA_DB_USER') { 'root' },
        password: ENV.fetch('ISUBATA_DB_PASSWORD') { '' },
        database: 'isubata',
        encoding: 'utf8mb4'
      )
      db_client.query('SET SESSION sql_mode=\'TRADITIONAL,NO_AUTO_VALUE_ON_ZERO,ONLY_FULL_GROUP_BY\'')
      @_users_from_db = db_client.query('SELECT id, name, display_name, avatar_icon FROM user').to_a.each_with_object({}) do |row, hash|
        hash[row['id']] = row
      end
    }
    enable :sessions
  end

  configure :development do
    require 'sinatra/reloader'
    require 'rack-mini-profiler'
    require 'pry'
    register Sinatra::Reloader
    use Rack::MiniProfiler
  end

  helpers do
    def user
      return @_user unless @_user.nil?

      user_id = session[:user_id]
      return nil if user_id.nil?

      @_user = get_user(user_id)
      if @_user.nil?
        params[:user_id] = nil
        return nil
      end

      @_user
    end
  end

  get '/initialize' do
    db.query("DELETE FROM user WHERE id > 1000")
    db.query("DELETE FROM image WHERE id > 1001")
    db.query("DELETE FROM channel WHERE id > 10")
    db.query("DELETE FROM message WHERE id > 10000")
    db.query("DELETE FROM haveread")
    204
  end

  get '/' do
    if session.has_key?(:user_id)
      return redirect '/channel/1', 303
    end
    erb :index
  end

  get '/channel/:channel_id' do
    if user.nil?
      return redirect '/login', 303
    end

    @channel_id = params[:channel_id].to_i
    @channels, @description = get_channel_list_info(@channel_id)
    erb :channel
  end

  get '/register' do
    erb :register
  end

  post '/register' do
    name = params[:name]
    pw = params[:password]
    if name.nil? || name.empty? || pw.nil? || pw.empty?
      return 400
    end
    begin
      user_id = register(name, pw)
    rescue Mysql2::Error => e
      return 409 if e.error_number == 1062
      raise e
    end
    session[:user_id] = user_id
    redirect '/', 303
  end

  get '/login' do
    erb :login
  end

  post '/login' do
    name = params[:name]
    statement = db.prepare('SELECT id, password, salt FROM user WHERE name = ? LIMIT 1')
    row = statement.execute(name).first
    # もしかして: hexdigetsとかって遅い？
    if row.nil? || row['password'] != Digest::SHA1.hexdigest(row['salt'] + params[:password])
      return 403
    end
    session[:user_id] = row['id']
    redirect '/', 303
  end

  get '/logout' do
    session[:user_id] = nil
    redirect '/', 303
  end

  post '/message' do
    user_id = session[:user_id]
    message = params[:message]
    channel_id = params[:channel_id]
    if user_id.nil? || message.nil? || channel_id.nil? || user.nil?
      return 403
    end
    db_add_message(channel_id.to_i, user_id, message)
    204
  end

  get '/message' do
    user_id = session[:user_id]
    if user_id.nil?
      return 403
    end

    channel_id = params[:channel_id].to_i
    last_message_id = params[:last_message_id].to_i
    query = <<~SQL
      SELECT msg.id AS id, msg.created_at, msg.content, user.name, user.display_name, user.avatar_icon
      FROM message AS msg INNER JOIN user ON msg.user_id = user.id
      WHERE msg.id > ? AND msg.channel_id = ? ORDER BY msg.id DESC LIMIT 100
    SQL
    statement = db.prepare(query)
    rows = statement.execute(last_message_id, channel_id).to_a
    response = rows.map do |row|
      { id: row['id'],
        user: {
          name: row['name'],
          display_name: row['display_name'],
          avatar_icon: row['avatar_icon']
        },
        date: row['created_at'].strftime("%Y/%m/%d %H:%M:%S"),
        content: row['content']
      }
    end.reverse

    max_message_id = rows.empty? ? 0 : rows.first['id']
    statement = db.prepare(<<~SQL
      INSERT INTO haveread (user_id, channel_id, message_id, updated_at, created_at)
      VALUES (?, ?, ?, NOW(), NOW())
      ON DUPLICATE KEY UPDATE message_id = ?, updated_at = NOW()
    SQL
    )
    statement.execute(user_id, channel_id, max_message_id, max_message_id)

    content_type :json
    response.to_json
  end

  get '/fetch' do
    user_id = session[:user_id]
    if user_id.nil?
      return 403
    end

    sleep 1.0

    rows = db.query('SELECT id FROM channel').to_a
    channel_ids = rows.map { |row| row['id'] }

    res = []
    channel_ids.each do |channel_id|
      # IDEA: channelごとにクエリするんじゃなくて、havereadもそんなに多くないからガツッとデータ持っておいてuserごとにメモリ上で引く方が良さそう
      statement = db.prepare('SELECT * FROM haveread WHERE user_id = ? AND channel_id = ?')
      row = statement.execute(user_id, channel_id).first
      statement.close
      r = {}
      r['channel_id'] = channel_id
      r['unread'] = if row.nil?
        # IDEA: COUNT(id) とかにする
        statement = db.prepare('SELECT COUNT(*) as cnt FROM message WHERE channel_id = ?')
        statement.execute(channel_id).first['cnt']
      else
        # IDEA: COUNT(id) とかにする
        statement = db.prepare('SELECT COUNT(*) as cnt FROM message WHERE channel_id = ? AND ? < id')
        statement.execute(channel_id, row['message_id']).first['cnt']
      end
      statement.close
      res << r
    end

    content_type :json
    # IDEA: to_jsonじゃなくてOj使う
    res.to_json
  end

  get '/history/:channel_id' do
    if user.nil?
      return redirect '/login', 303
    end

    @channel_id = params[:channel_id].to_i

    @page = params[:page]
    if @page.nil?
      @page = '1'
    end

    begin
      @page = Integer(@page)
    rescue ArgumentError
      return 400
    end
    return 400 if @page < 1

    n = 20
    query = <<~SQL
      SELECT msg.id AS id, msg.created_at, msg.content, user.name, user.display_name, user.avatar_icon
      FROM message AS msg INNER JOIN user ON msg.user_id = user.id
      WHERE msg.channel_id = ? ORDER BY msg.id DESC LIMIT ? OFFSET ?
    SQL
    rows = db.prepare(query).execute(@channel_id, n, (@page - 1) * n).to_a
    @messages = rows.map do |row|
      { 'id' => row['id'],
        'user' => {
          'name' => row['name'],
          'display_name' => row['display_name'],
          'avatar_icon' => row['avatar_icon']
        },
        'date' => row['created_at'].strftime("%Y/%m/%d %H:%M:%S"),
        'content' => row['content']
      }
    end.reverse
    statement = db.prepare('SELECT COUNT(id) as cnt FROM message WHERE channel_id = ?')
    cnt = statement.execute(@channel_id).first['cnt'].to_f
    statement.close
    @max_page = cnt == 0 ? 1 :(cnt / n).ceil

    return 400 if @page > @max_page

    @channels, @description = get_channel_list_info(@channel_id)
    erb :history
  end

  get '/profile/:user_name' do
    if user.nil?
      return redirect '/login', 303
    end

    @channels, = get_channel_list_info

    user_name = params[:user_name]
    # IDEA: selectするカラムを絞る
    statement = db.prepare('SELECT * FROM user WHERE name = ?')
    @user = statement.execute(user_name).first
    statement.close

    if @user.nil?
      return 404
    end

    @self_profile = user['id'] == @user['id']
    erb :profile
  end

  get '/add_channel' do
    if user.nil?
      return redirect '/login', 303
    end

    @channels, = get_channel_list_info
    erb :add_channel
  end

  post '/add_channel' do
    if user.nil?
      return redirect '/login', 303
    end

    name = params[:name]
    description = params[:description]
    if name.nil? || description.nil?
      return 400
    end
    statement = db.prepare('INSERT INTO channel (name, description, updated_at, created_at) VALUES (?, ?, NOW(), NOW())')
    statement.execute(name, description)
    channel_id = db.last_id
    statement.close
    redirect "/channel/#{channel_id}", 303
  end

  post '/profile' do
    if user.nil?
      return redirect '/login', 303
    end

    if user.nil?
      return 403
    end

    display_name = params[:display_name]
    avatar_name = nil
    avatar_data = nil

    file = params[:avatar_icon]
    unless file.nil?
      filename = file[:filename]
      if !filename.nil? && !filename.empty?
        ext = filename.include?('.') ? File.extname(filename) : ''
        unless ['.jpg', '.jpeg', '.png', '.gif'].include?(ext)
          return 400
        end

        if settings.avatar_max_size < file[:tempfile].size
          return 400
        end

        data = file[:tempfile].read
        digest = Digest::SHA1.hexdigest(data)

        avatar_name = digest + ext
        avatar_data = data
      end
    end

    avatar_is_present = !avatar_name.nil? && !avatar_data.nil?
    display_name_is_present = !display_name.nil? || !display_name.empty?

    if avatar_is_present
      open("../public/icons/#{avatar_name}", 'wb') do |file|
        file.print(avatar_data)
      end
    end

    if avatar_is_present && display_name_is_present
      statement = db.prepare('UPDATE user SET avatar_icon = ?, display_name = ? WHERE id = ?')
      statement.execute(avatar_name, display_name, user['id'])
      statement.close
    elsif avatar_is_present
      statement = db.prepare('UPDATE user SET avatar_icon = ? WHERE id = ?')
      statement.execute(avatar_name, user['id'])
      statement.close
    elsif display_name_is_present
      statement = db.prepare('UPDATE user SET display_name = ? WHERE id = ?')
      statement.execute(display_name, user['id'])
      statement.close
    end

    redirect '/', 303
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

  def get_user(user_id)
    settings.users_from_db.fetch(user_id, db_get_user(user_id))
  end

  def db_get_user(user_id)
    statement = db.prepare('SELECT id, name, display_name, avatar_icon FROM user WHERE id = ? LIMIT 1')
    user = statement.execute(user_id).first
    statement.close
    user
  end

  def db_add_message(channel_id, user_id, content)
    statement = db.prepare('INSERT INTO message (channel_id, user_id, content, created_at) VALUES (?, ?, ?, NOW())')
    messages = statement.execute(channel_id, user_id, content)
    statement.close
    messages
  end

  def random_string(n)
    # IDEA: saltとか固定でよくね？あるいは定数化するなり組み込みのクラス使うなりで高速化
    Array.new(20).map { (('a'..'z').to_a + ('A'..'Z').to_a + ('0'..'9').to_a).sample }.join
  end

  def register(user, password)
    salt = random_string(20)
    pass_digest = Digest::SHA1.hexdigest(salt + password)
    statement = db.prepare('INSERT INTO user (name, salt, password, display_name, avatar_icon, created_at) VALUES (?, ?, ?, ?, ?, NOW())')
    statement.execute(user, salt, pass_digest, user, 'default.png')
    row = db.query('SELECT LAST_INSERT_ID() AS last_insert_id').first
    statement.close
    row['last_insert_id']
  end

  def get_channel_list_info(focus_channel_id = nil)
    channels = db.query('SELECT * FROM channel ORDER BY id').to_a
    description = ''
    channels.each do |channel|
      if channel['id'] == focus_channel_id
        description = channel['description']
        break
      end
    end
    [channels, description]
  end
end
