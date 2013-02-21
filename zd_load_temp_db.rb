require 'nokogiri'
require 'rubygems'
require 'sequel'
 
#Connect to DB
 
DB = Sequel.connect(:adapter=>'mysql', :host=>'127.0.0.1', :database=>'zd_name', :user=>'root', :password=>'')
user_table = DB[:zd_users]
tickets_table = DB[:zd_tickets]
comments_table = DB[:zd_comments]
 
# Read Zendesk XML into DB #    
user_xml = Nokogiri::XML(open("import/users.xml"))
 
#Write Users to DB
user_xml.xpath('//user').each do |user|
    puts " - #{ user.xpath('name').text } ( #{ user.xpath('email').text } ) #{ user.xpath('phone').text }"
    user_table.insert(:zd_id => user.xpath('id').text, :name => user.xpath('name').text, :email => user.xpath('email').text.empty? ? nil : user.xpath('email').text, :role =>user.xpath('roles').text)
end
 
# Open Ticket XML
 
ticket_xml = Nokogiri::XML(open("import/tickets.xml"))
 
#Write Tickets and Comments to  to DB
ticket_xml.xpath('//ticket').each do |ticket|
  
puts " - #{ ticket.xpath('nice-id').text } :: #{ ticket.xpath('subject').text }"
 
  tickets_table.insert(:zd_id => ticket.xpath('nice-id').text, :created_at => ticket.xpath('created-at').text, :tags => ticket.xpath('current-tags').text.empty? ? nil : ticket.xpath('current-tags').text.gsub(" ", ","), :subject =>ticket.xpath('subject').text, :group_id =>ticket.xpath('group-id').text, :status_id =>ticket.xpath('status-id').text)
 
  ticket.css('comment').each do |comment|
    puts "    --#{ comment.xpath('created-at').text } :: #{ comment.xpath('author-id').text }"
 
    comments_table.insert(:zd_ticket_id => ticket.xpath('nice-id').text, :zd_user_id => comment.xpath('author-id').text, :created_at => comment.xpath('created-at').text, :body =>comment.xpath('value').text, :to =>ticket.xpath('recipient').text, :public =>comment.xpath('is-public').text == 'true' ? 1 : 0)
  end
end
 
DB.disconnect
