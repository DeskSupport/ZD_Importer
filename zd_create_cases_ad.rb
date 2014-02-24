# http://sequel.rubyforge.org/rdoc/files/doc/cheat_sheet_rdoc.html
require 'rubygems'
require 'json'
require 'sequel'
require 'oauth'
require 'yajl'
require 'yaml'

SITE_URL = "https://mycompany.desk.com"
API_CONSUMER_KEY = ""
API_CONSUMER_SECRET = ""
API_TOKEN_KEY = ""
API_TOKEN_SECRET = ""

# Setup parser and encoder
def parse(response)
  Yajl::Parser.parse(response.body)
end
def encode(obj)
  Yajl::Encoder.encode(obj)
end

def log(message)
  puts message
  File.open("import.log", 'a') {|f| f.write("#{message}\n") }
end

def request(method, uri, params = {})
  begin
    response = @access_token.request(method, SITE_URL + uri, params)
    parser = Yajl::Parser.new
    json = parser.parse(response.body)

    #puts json

    if response.code == "200" || response.code == "201"
      return json['results']
    elsif json["error"] == "rate_limit_exceeded"
       puts response
       puts "Waiting for rate limit"
       sleep 1
       return "ratelimited"
    else
      puts json.inspect
      puts "JSON Response: #{json}"
      log "Params: #{params}"
      json['errors'].each {|error| log("ERROR MESSAGE: #{error}") }

      unless (json['errors'].nil?)
        if (json['errors'][0].include?("Unable to find or create customer with email address") || json['errors'][0].include?("Email is invalid."))
          puts "Going to retry with default email..."
          params['customer_email'] = "invalid-email@example.com"
          return request(method, uri, params)
        end
      end

      return json
    end
  rescue => e
    puts "Womg: #{e}"
    puts "Taking a nap..."
    sleep(5)
    retry
  end
end

#Connect to DB

DB = Sequel.connect(:adapter=>'mysql', :host=>'127.0.0.1', :database=>'zd_mycompany', :user=>'root', :password=>'mypassword')
tickets_table = DB[:zd_tickets]
comments_table = DB[:zd_comments]

#Connect to Desk.com API
# Exchange api keys for an access token instance to perform api requests
consumer = OAuth::Consumer.new(API_CONSUMER_KEY, API_CONSUMER_SECRET, { :site => SITE_URL, :scheme => :header })
@access_token = OAuth::AccessToken.from_hash(consumer, :oauth_token => API_TOKEN_KEY, :oauth_token_secret => API_TOKEN_SECRET)


#Read Zendesk Comments and create cases
last_case_id = nil
last_external_case_id = nil
last_status_id = nil
last_group_id = nil
last_agent_id = nil
last_case_subject = nil
last_labels = nil

DB['select t.zd_id as "external_id", c.created_at as "comment_created", c.id as "temp_comment_id", c.desk_id as "desk_interaction_id", t.desk_id as "desk_ticket_display_id",  t.created_at as "ticket_created", t.zd_id as "case_custom_zd", t.subject as "interaction_subject", concat(t.subject, \' (\',DATE_FORMAT(t.created_at,\'%c/%e/%y %l:%i%p\'),\')\') as "case_subject", c.body as "interaction_body", c.public as "interaction_public", ifnull(u.email,concat(\'ads-\',u.zd_id, \'@unknown.com\')) as "customer_email", u.name as "customer_name", t.tags as "case_labels", t.group_id as "group_id", t.agent_id as "agent_id", t.status_id as "status_id", if(u.email is null, \'phone\',\'email\') as "interaction_channel" from zd_comments as c left join zd_tickets t on t.zd_id = c.zd_ticket_id left join zd_users u on u.zd_id = c.zd_user_id where c.desk_id is null and t.status_id < 999 and c.zd_user_id != -1 order by 1,2;'].each do |row|
  #puts "last_case_id = #{ last_case_id } and row[:external_id] = #{ row[:external_id] }"

  if row[:interaction_subject].include? "&amp;"
    row[:interaction_subject] = row[:interaction_subject].gsub(/&amp;/, "&")
    #puts "(Interaction Subject -> Replaced &amp; with &)"
  end
  
  if row[:interaction_body].include? "&amp;"
    row[:interaction_body] = row[:interaction_body].gsub(/&amp;/, "&")
    #puts "(Interaction Body -> Replaced &amp; with &)"
  end

  row[:interaction_body] = "From: " + row[:customer_name] + "\n" + DateTime.parse(row[:comment_created].to_s).strftime('%m/%d/%Y at %-I:%M %P ET') + "\n\n" + row[:interaction_body]

  if last_case_id == row[:external_id]
    if row[:interaction_public] == true

      if row[:interaction_public] == false
        row[:interaction_body] = "* Private Comment * \n\n" + row[:interaction_body]
      end

      new_interaction = {
        "case_id" => @desk_case_id,
        "interaction_subject" => row[:interaction_subject],
        "interaction_body" => row[:interaction_body],
        "customer_email" => row[:customer_email],
        "customer_name" => row[:customer_name]
      }
      comment = request(:post, '/api/v1/interactions.json', new_interaction)
      redo if comment == "ratelimited"
      puts "  - New interaction (case #{@desk_case_id})"

      comments_table.filter(:id => row[:temp_comment_id]).update(:desk_id => comment['interaction']['id'])
    else
      new_comment = {
        :body => row[:interaction_body].gsub("%", "&#37")
      }
      comment = request(:post, "/api/v2/cases/#{@desk_case_id}/notes", encode(new_comment))
      redo if comment == "ratelimited"
      puts "  - New comment (case #{@desk_case_id})"

      comments_table.filter(:id => row[:temp_comment_id]).update(:desk_id => 0)
    end
  else

    unless last_case_id.nil?
      #Update Case Subject and Status of last case

      case last_status_id
        when 0 then set_status = 10 #New
        when 1 then set_status = 30 #Open
        when 2 then set_status = 50 #Pending
        when 3 then set_status = 70 #Resolved
        else set_status = 70 #Resolved
      end

      case last_group_id
        when 12345 then set_group = 67890 # Example
        else set_group = ""
      end

      case last_agent_id
        when 12345 then set_agent = 67890 # Example
        else set_agent = ""
      end

      case_update = {
        "case_status_type_id" => set_status,
        "group_id" => set_group,
        "user_id" => set_agent,
        "labels" => last_labels,
        "subject" => last_case_subject
      }
      updated_case = request(:put, "/api/v1/cases/#{last_external_case_id}.json", case_update)['case']  
      redo if updated_case == "ratelimited"   
      puts "Updated case #{last_external_case_id} (status: #{set_status}, group: #{set_group})"
    end

    # Add zendesk label
    row[:case_labels] = "Imported,#{row[:case_labels]}"

    if row[:customer_email].nil?
      row[:customer_email] = "support@mycompany.com"
    end

    new_case = {
      "case_external_id" => row[:external_id],
      "case_custom_zd" => row[:case_custom_zd],
      "case_custom_imported" => 1,
      "interaction_subject" => row[:interaction_subject],
      "interaction_body" => row[:interaction_body],
      "customer_email" => row[:customer_email],
      "customer_name" => row[:customer_name],
      "interaction_channel" => "email"
    }
    desk_case = request(:post, '/api/v1/interactions.json', new_case)  
    redo if desk_case == "ratelimited"    
    @desk_case_id = "#{ desk_case['case']['id'] }"
    puts "\nCreated case #{@desk_case_id} (labels: #{row[:case_labels]})"

    tickets_table.filter(:zd_id => row[:case_custom_zd]).update(:desk_id => @desk_case_id)
    comments_table.filter(:id => row[:temp_comment_id]).update(:desk_id => desk_case['interaction']['id'])

    # Set last stuff
    last_case_id = row[:external_id]
    last_status_id = row[:status_id]
    last_group_id = row[:group_id]
    last_agent_id = row[:agent_id]
    last_case_subject = row[:case_subject]
    last_labels = row[:case_labels]
    last_external_case_id = @desk_case_id

  end

end

DB.disconnect
