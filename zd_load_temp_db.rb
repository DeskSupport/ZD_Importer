require 'nokogiri'
require 'rubygems'
require 'sequel'
require 'json'

# Read Zendesk XML into DB #    
user_xml = Nokogiri::XML(open("mycompany-20140224/users.xml"))

#Connect to DB

DB = Sequel.connect(:adapter=>'mysql', :host=>'127.0.0.1', :database=>'zd_mycompany', :user=>'root', :password=>'qazqaz1')
user_table = DB[:zd_users]
tickets_table = DB[:zd_tickets]
comments_table = DB[:zd_comments]


#Write Users to DB
user_xml.xpath('//user').each do |user|
    puts " - #{ user.xpath('name').text } ( #{ user.xpath('email').text } ) #{ user.xpath('phone').text }"
    user_table.insert(:zd_id => user.xpath('id').text, :name => user.xpath('name').text, :email => user.xpath('email').text.empty? ? nil : user.xpath('email').text, :role =>user.xpath('roles').text)
end

# Open Ticket XML
ticket_xml = Nokogiri::XML(open("mycompany-20140224/tickets.xml"))

#Write Tickets and Comments to  to DB
ticket_xml.xpath('//ticket').each do |ticket|
	thing = []
  ticket.xpath('ticket-field-entries/ticket-field-entry').each do |cur|
  	thing << {
  		:field_id => cur.xpath('ticket-field-id').text, 
  		:value => cur.xpath('value').text
  	} 
  end
  custom_fields = thing.to_json

  puts " - #{ ticket.xpath('nice-id').text } :: #{ ticket.xpath('subject').text }"
  tickets_table.insert(:zd_id => ticket.xpath('nice-id').text, :created_at => ticket.xpath('created-at').text, :tags => ticket.xpath('current-tags').text.empty? ? nil : ticket.xpath('current-tags').text.gsub(" ", ","), :subject =>ticket.xpath('subject').text, :group_id =>ticket.xpath('group-id').text.to_i, :agent_id =>ticket.xpath('assignee-id').text.to_i, :status_id =>ticket.xpath('status-id').text, :custom_fields => custom_fields)

  ticket.css('comment').each do |comment|
    puts "    --#{ comment.xpath('created-at').text } :: #{ comment.xpath('author-id').text }"
    comments_table.insert(:zd_ticket_id => ticket.xpath('nice-id').text, :zd_user_id => comment.xpath('author-id').text, :created_at => comment.xpath('created-at').text, :body =>comment.xpath('value').text, :public =>comment.xpath('is-public').text == 'true' ? 1 : 0)
  end

end




DB.disconnect
