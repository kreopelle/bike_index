require 'spec_helper'

describe 'Bikes API V2' do
  JSON_CONTENT = { 'CONTENT_TYPE' => 'application/json', 'ACCEPT' => 'application/json' }
  

  describe 'find by id' do
    before :all do
      create_doorkeeper_app
    end
    it "returns one with from an id" do
      bike = FactoryGirl.create(:bike)
      get "/api/v2/bikes/#{bike.id}", :format => :json, :access_token => @token.token
      result = response.body
      response.code.should == '200'
      expect(JSON.parse(result)['bike']['id']).to eq(bike.id)
    end

    it "responds with missing" do 
      token = Doorkeeper::AccessToken.create!(application_id: @application.id, resource_owner_id: @user.id)
      get "/api/v2/bikes/10", :format => :json, :access_token => token.token
      response.code.should == '404'
      expect(JSON(response.body)["message"].present?).to be_true
    end
  end

  describe 'create' do
    before :each do 
      create_doorkeeper_app({scopes: 'read_bikes write_bikes'})
      manufacturer = FactoryGirl.create(:manufacturer)
      color = FactoryGirl.create(:color)
      FactoryGirl.create(:wheel_size, iso_bsd: 559)
      FactoryGirl.create(:cycle_type, slug: "bike")
      FactoryGirl.create(:propulsion_type, name: "Foot pedal")
      @bike = { serial: "69 non-example",
        manufacturer: manufacturer.name,
        rear_tire_narrow: "true",
        rear_wheel_bsd: "559",
        color: color.name,
        year: '1969',
        owner_email: "fun_times@examples.com"
      }
    end

    it "responds with 401" do 
      post "/api/v2/bikes", @bike.to_json
      response.code.should == '401'
    end

    it "fails if the token doesn't have write_bikes scope" do 
      @token.update_attribute :scopes, 'read_bikes'
      post "/api/v2/bikes?access_token=#{@token.token}", @bike.to_json, JSON_CONTENT
      response.code.should eq('403')
    end

    it "creates a non example bike" do 
      manufacturer = FactoryGirl.create(:manufacturer)
      FactoryGirl.create(:ctype, name: "wheel")
      FactoryGirl.create(:ctype, name: "Headset")
      components = [
        {
          manufacturer: manufacturer.name,
          year: "1999",
          component_type: 'headset',
          description: "yeah yay!",
          serial_number: '69',
          model_name: 'Richie rich'
        },
        {
          manufacturer: "BLUE TEETH",
          front_or_rear: "Both",
          component_type: 'wheel'
        }
      ]
      @bike.merge!({components: components})
      expect{
        post "/api/v2/bikes?access_token=#{@token.token}",
          @bike.to_json,
          JSON_CONTENT
      }.to change(EmailOwnershipInvitationWorker.jobs, :size).by(1)
      response.code.should eq("201")
      result = JSON.parse(response.body)['bike']
      result['serial'].should eq(@bike[:serial])
      result['manufacturer_name'].should eq(@bike[:manufacturer])
      bike = Bike.find(result['id'])
      bike.example.should be_false
      bike.components.count.should eq(3)
      bike.components.pluck(:manufacturer_id).include?(manufacturer.id).should be_true
      bike.components.pluck(:ctype_id).uniq.count.should eq(2)
    end

    it "creates an example bike" do
      FactoryGirl.create(:organization, name: "Example organization")
      expect{
        post "/api/v2/bikes?access_token=#{@token.token}",
          @bike.merge(test: true).to_json,
          JSON_CONTENT
      }.to change(EmailOwnershipInvitationWorker.jobs, :size).by(0)
      response.code.should eq("201")
      result = JSON.parse(response.body)['bike']
      result['serial'].should eq(@bike[:serial])
      result['manufacturer_name'].should eq(@bike[:manufacturer])
      Bike.unscoped.find(result['id']).example.should be_true
    end

    it "fails to create a bike if the user isn't a member of the organization" do
      org = FactoryGirl.create(:organization, name: "Something")
      bike = @bike.merge(organization_slug: org.slug)
      post "/api/v2/bikes?access_token=#{@token.token}",
        bike.to_json,
        JSON_CONTENT
      response.code.should eq("401")
      result = JSON.parse(response.body)
      result['error'].kind_of?(String).should be_true
    end

    it "creates a stolen bike through an organization" do 
      organization = FactoryGirl.create(:organization)
      FactoryGirl.create(:membership, user: @user, organization: organization)
      FactoryGirl.create(:country, iso: "US")
      FactoryGirl.create(:state, abbreviation: "Palace")
      organization.save
      bike = @bike.merge(organization_slug: organization.slug)
      date_stolen = 1357192800
      bike[:stolen_record] = {
        phone: '1234567890',
        date_stolen: date_stolen,
        theft_description: "This bike was stolen and that's no fair.",
        country: "US",
        city: 'Chicago',
        street: "Cortland and Ashland",
        zipcode: "60622",
        state: "Palace",
        police_report_number: "99999999",
        police_report_department: "Chicago",
        # locking_description: 'some locking description',
        # lock_defeat_description: 'broken in some crazy way'
      }
      expect{
        post "/api/v2/bikes?access_token=#{@token.token}", 
          bike.to_json,
          JSON_CONTENT
      }.to change(EmailOwnershipInvitationWorker.jobs, :size).by(1)
      result = JSON.parse(response.body)['bike']
      result['serial'].should eq(@bike[:serial])
      result['manufacturer_name'].should eq(@bike[:manufacturer])
      result['stolen_record']['date_stolen'].should eq(date_stolen)
      b = Bike.find(result['id'])
      b.creation_organization.should eq(organization)
      b.stolen.should be_true
      b.current_stolen_record_id.should be_present
      b.current_stolen_record.police_report_number.should eq(bike[:stolen_record][:police_report_number])
    end

    it "does not register a stolen bike unless attrs are present" do

    end
  end

  describe 'update' do
    before :each do 
      create_doorkeeper_app({scopes: 'read_user write_bikes'})
      @bike = FactoryGirl.create(:ownership, creator_id: @user.id).bike
      @params = {
        year: 1999,
        serial_number: 'XXX69XXX'
      }
      @url = "/api/v2/bikes/#{@bike.id}?access_token=#{@token.token}"
    end

    it "doesn't update if user doesn't own the bike" do 
      @bike.current_ownership.update_attributes(user_id: FactoryGirl.create(:user), claimed: true)
      Bike.any_instance.should_receive(:type).and_return('unicorn')
      put @url, @params.to_json, JSON_CONTENT
      response.code.should eq('403') 
      response.body.match('do not own that unicorn').should be_present
    end

    it "doesn't update if not in scope" do 
      @token.update_attribute :scopes, 'public'
      put @url, @params.to_json, JSON_CONTENT
      response.code.should eq('403') 
      response.body.match('scope').should be_present
    end

    it "fails to update bike if required stolen attrs aren't present" do
      FactoryGirl.create(:country, iso: "US")
      @bike.year.should be_nil
      serial = @bike.serial_number
      @params[:stolen_record] = {
        phone: '',
        city: 'Chicago'
      }
      put @url, @params.to_json, JSON_CONTENT
      response.code.should eq('401')
      response.body.match('missing phone').should be_present
    end

    it "updates a bike, adds a stolen record, doesn't update locked attrs" do
      FactoryGirl.create(:country, iso: "US")
      @bike.year.should be_nil
      serial = @bike.serial_number
      @params[:stolen_record] = {
        city: 'Chicago',
        phone: '1234567890',
        police_report_number: "999999"
      }
      put @url, @params.to_json, JSON_CONTENT
      response.code.should eq('200')
      @bike.reload.year.should eq(@params[:year])
      @bike.serial_number.should eq(serial)
      @bike.stolen.should be_true
      @bike.current_stolen_record.date_stolen.to_i.should be > Time.now.to_i - 10
      @bike.current_stolen_record.police_report_number.should eq("999999")
    end

    it "updates a bike, adds a stolen record, doesn't update locked attrs" do
      stolen_record = FactoryGirl.create(:stolen_record, bike: @bike)
      @bike.reload.update_attribute :stolen, true
      @bike.current_stolen_record.should eq(stolen_record)
      @params[:stolen_record] = {
        city: 'Chicago',
        police_report_number: "999999"
      }
      put @url, @params.to_json, JSON_CONTENT
      result = JSON.parse(response.body)['bike']
      response.code.should eq('200')
      @bike.reload.year.should eq(@params[:year])
      @bike.stolen.should be_true
      result['stolen_record']['police_report_number'].should eq("999999")
    end

    it "claims a bike and updates if it should" do 
      @bike.year.should be_nil
      @bike.current_ownership.update_attributes(owner_email: @user.email, creator_id: FactoryGirl.create(:user).id, claimed: false)
      @bike.reload.owner.should_not eq(@user)
      put @url, @params.to_json, JSON_CONTENT
      response.code.should eq('200')
      @bike.reload.current_ownership.claimed.should be_true
      @bike.owner.should eq(@user)
      @bike.year.should eq(@params[:year])
    end
  end

  describe :send_stolen_notification do 
    before :each do 
      create_doorkeeper_app({scopes: 'read_user'})
      @bike = FactoryGirl.create(:ownership, creator_id: @user.id).bike
      @bike.update_attribute :stolen, true
      @params = {message: "Something I'm sending you"}
      @url = "/api/v2/bikes/#{@bike.id}/send_stolen_notification?access_token=#{@token.token}"
    end

    it "fails to send a stolen notification without read_user" do
      @token.update_attribute :scopes, 'public'
      post @url, @params.to_json, JSON_CONTENT
      response.code.should eq('403')
      response.body.match('scope').should be_present
      response.body.match('is not stolen').should_not be_present
    end

    it "fails if the bike isn't stolen" do 
      @bike.update_attribute :stolen, false
      post @url, @params.to_json, JSON_CONTENT
      response.code.should eq('400')
      response.body.match('is not stolen').should be_present
    end

    it "fails if the bike isn't owned by the access token user" do
      @bike.current_ownership.update_attributes(user_id: FactoryGirl.create(:user), claimed: true)
      post @url, @params.to_json, JSON_CONTENT
      response.code.should eq('403')
      response.body.match('application is not approved').should be_present
    end

    it "sends a notification" do 
      expect{
        post @url, @params.to_json, JSON_CONTENT
      }.to change(EmailStolenNotificationWorker.jobs, :size).by(1)
      response.code.should eq('201')
    end
  end

end