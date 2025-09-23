//
//  SignIn.swift
//  NoMADLogin
//
//  Created by Joel Rennich on 9/20/17.
//  Copyright © 2017 Joel Rennich. All rights reserved.
//

import Cocoa
import Security.AuthorizationPlugin
import os.log
import OpenDirectory
import OIDCLite
import CryptoTokenKit
import CryptoKit
let uiLog = OSLog(subsystem: "menu.nomad.login.ad", category: "UI")
let checkADLog = OSLog(subsystem: "menu.nomad.login.ad", category: "CheckADMech")

protocol UpdateCredentialsFeedbackProtocol {

    func passwordExpiryUpdate(_ passwordExpires:Date)
    func credentialsUpdated(_ credentials:Creds)
    func credentialsCheckFailed()
    func invalidCredentials()
    func kerberosTicketUpdated()
    func kerberosTicketCheckFailed(_ error:NoMADSessionError)
    func adUserUpdated(_ adUser:ADUserRecord)

}
@available(macOS, deprecated: 11)
@objc class SignInViewController: NSViewController, DSQueryable, TokenManagerFeedbackDelegate {


    enum SignInViewControllerResetPasswordError:Error {
        case failedToResetPassword(String)
        case cancelled

    }

    //MARK: - setup properties
    var mech: MechanismRecord?
    var nomadSession: NoMADSession?
    var shortName = ""
    var domainName = ""
    var passString = ""
    var newPassword = ""
    var isDomainManaged = false
    var isSSLRequired = false
    let sysInfo = SystemInfoHelper().info()
    var sysInfoIndex = 0
    let tokenManager = TokenManager()
    var cardLoginFailedAttempts = 0
    var localAdmin:LocalAdminCredentials?
    var rfidUsers:RFIDUsers?
    var updateCredentialsFeedbackDelegate: UpdateCredentialsFeedbackProtocol?
    var isInUserSpace = false
    var watcher:TKTokenWatcher?
    var isResetPasswordInProgress = false
    var shouldIgnoreInsertion=false
    var hadPasswordFailure:Bool=false

    @objc var visible = true
    override var acceptsFirstResponder: Bool {
        return true
    }
    //MARK: - IB outlets
    @IBOutlet weak var usernameTextField: NSTextField!
    @IBOutlet weak var passwordTextField: NSSecureTextField!
    @IBOutlet weak var localOnlyCheckBox: NSButton!
//    @IBOutlet weak var localOnlyView: NSView!
    @IBOutlet var alertTextField:NSTextField!
    @IBOutlet var tapLoginLabel:NSTextField!

    @IBOutlet weak var loginCardSetupButton: NSButton!
//    @IBOutlet weak var loginCardSetupView: NSView!
    var unprovisionedRfidUid:String?
    @IBOutlet weak var stackView: NSStackView!

//    @IBOutlet weak var domain: NSPopUpButton!
    @IBOutlet weak var signIn: NSButton!
    @IBOutlet weak var imageView: NSImageView!
//    var setupCardWindowController:SetupCardWindowController?

    @IBOutlet weak var logoImageView: NSImageView!
    var mechanismDelegate:XCredsMechanismProtocol?

    override var nibName: NSNib.Name{

        return "LocalUsersViewController"
    }
    func invalidCredentials() {
        updateCredentialsFeedbackDelegate?.invalidCredentials()
        TCSLogWithMark("Token error: Invalid credentials")
        XCredsAudit().auditError("Token error: Invalid credentials")
        shakeWindowAndShowError()

    }

    func tokenError(_ err:String){
        updateCredentialsFeedbackDelegate?.credentialsCheckFailed()
        TCSLogWithMark("Token error: \(err)")
        XCredsAudit().auditError(err)
        shakeWindowAndShowError()
    }

    func credentialsUpdated(_ credentials:Creds){

        updateCredentialsFeedbackDelegate?.credentialsUpdated(credentials)
        if let res = mechanismDelegate?.setupHints(fromCredentials: credentials, password: passString ){
            switch res {
                
            case .success, .userCancelled:
                break
            case .failure(let msg):
                TCSLogWithMark(msg)
                TCSLogWithMark("error setting up hints, reloading page:\(msg)")
                let alert = NSAlert()
                alert.addButton(withTitle: "OK")
                alert.messageText=msg
                
                alert.window.canBecomeVisibleWithoutLogin=true
                
                let bundle = Bundle.findBundleWithName(name: "XCreds")
                
                if let bundle = bundle {
                    TCSLogWithMark("Found bundle")
                    alert.icon=bundle.image(forResource: NSImage.Name("icon_128x128"))
                }
                alert.runModal()
            }

        }

        var credWithPass = credentials
        credWithPass.password = self.passString
        NotificationCenter.default.post(name: Notification.Name("TCSTokensUpdated"), object: self, userInfo:["credentials":credWithPass])

    }




//    var mechanism:XCredsMechanismProtocol? {
//        set {
//            TCSLogWithMark()
//            mechanismDelegate=newValue
//        }
//        get {
//            return mechanismDelegate
//        }
//    }

    //MARK: - Migrate Box IB outlets
    var migrate = false
    var migrateUserRecord : ODRecord?
//    var didUpdateFail = false
    var setupDone=false
    var cardInserted = false
    //MARK: - UI Methods

    override func awakeFromNib() {
        super.awakeFromNib()
        //awakeFromNib gets called multiple times. guard against that.
        if setupDone==true {
            return
        }
        setupDone=true

        TCSLogWithMark()
        alertTextField.isHidden=true

        if let prefDomainName=getManagedPreference(key: .ADDomain) as? String{
            domainName = prefDomainName
        }
        setupLoginAppearance()

        TCSLogWithMark("setting up smart card listener")
        watcher = TKTokenWatcher()
        watcher?.setInsertionHandler({ tokenID in
            TCSLogWithMark("card inserted")
            //sometimes we get multiple events, so track and skip

            self.watcher?.addRemovalHandler({ tokenID in
                self.loginCardSetupButton.isHidden=true
                self.loginCardSetupButton.state = .off
                self.unprovisionedRfidUid=nil
                self.cardInserted=false

                TCSLogWithMark("card removed")
            }, forTokenID: tokenID)
            if self.cardInserted == true {
                return
            }
            self.cardInserted=true
            
            if self.shouldIgnoreInsertion == true {
                return
            }
            if self.cardLoginFailedAttempts>2 {
                DispatchQueue.main.async {
                    self.alertTextField.stringValue = "Tap Login Disabled"
                    self.alertTextField.isHidden = false
                }
                return
            }
            let slotNames = TKSmartCardSlotManager.default?.slotNames

            guard let slotNames = slotNames, slotNames.count>0 else {
                TCSLogWithMark("No rfid readers")
                return
            }
            guard let ccidSlotName = DefaultsOverride.standardOverride.string(forKey: PrefKeys.ccidSlotName.rawValue) else {
                TCSLogWithMark("No slotname defined in prefs. Slot names found: \(slotNames)")

                return
            }
            let slotName=slotNames.first { currString in
                currString == ccidSlotName
            }

            guard let slotName = slotName else {
                TCSLogWithMark("no matches found for slotname \(ccidSlotName)")
                return
            }
            TCSLogWithMark()
            let slot = TKSmartCardSlotManager.default?.slotNamed(slotName)
            TCSLogWithMark()
            guard let tkSmartCard = slot?.makeSmartCard() else {
                TCSLogWithMark("Could not setup reader")
                self.cardInserted=false
                return
            }
            TCSLogWithMark()
            let builtInReader = CCIDCardReader(tkSmartCard: tkSmartCard)
            TCSLogWithMark()
            let returnData = builtInReader.sendAPDU(cla: 0xFF, ins: 0xCA, p1: 0, p2: 0, data: nil)
            TCSLogWithMark()
            if let returnData=returnData, returnData.count>2{
                TCSLogWithMark()
                print(returnData[0...returnData.count-3].hexEncodedString())
                DispatchQueue.main.async {
                    TCSLogWithMark()

                    var pin:String?
                    let hex=returnData[0...returnData.count-3].hexEncodedString()
                    do {
                        let secretKeeper = try SecretKeeper(label: "XCreds Encryptor", tag: "XCreds Encryptor")
                        let userManager = UserSecretManager(secretKeeper: secretKeeper)
                        if let uidData = Data(fromHexEncodedString: hex) {
                            TCSLogWithMark("got UID Data")
                            if let user = try userManager.uidUser(uid: uidData, rfidUsers: self.rfidUsers){
                                TCSLogWithMark("Found user. looking if pin required")
                                if user.requiresPIN == true {
                                    let pinPromptWindowController = PinPromptWindowController(windowNibName: "PinPromptWindowController")
                                    let res = NSApp.runModal(for: pinPromptWindowController.window!)
                                    pinPromptWindowController.window?.close()

                                    if res == .OK {
                                        pin = pinPromptWindowController.pin
                                    }
                                    else if res == .cancel {
                                        return
                                    }

                                }

                            }
                        }
                        self.cardLogin(uid: hex, pin:pin)
                    }
                    catch {
                        TCSLogWithMark("error: "+error.localizedDescription)

                    }
                }
            }
        })

    }




    func cardLogin(uid:String, pin:String?) {
        var hashedUID:Data
        let shouldAllowLoginCardSetup = DefaultsOverride.standardOverride.bool(forKey: PrefKeys.shouldAllowLoginCardSetup.rawValue)

        TCSLogWithMark("RFID UID \"\(uid)\" detected")
        guard let rfidUsers = rfidUsers else {
            if shouldAllowLoginCardSetup == true {
                loginCardSetupButton.isHidden=false
                self.loginCardSetupButton.state = .on

                unprovisionedRfidUid=uid
            }
            else {
                TCSLogWithMark("No RFID Users defined. run /Applications/XCreds.app/Contents/MacOS/XCreds -h for help on adding users.")

                passwordTextField.shake(self)

            }
            return
        }

        guard let rfidUidData = Data(fromHexEncodedString: uid) else {
            TCSLogWithMark("error in RFID UID")
            return
        }

        do {
            (hashedUID,_) = try PasswordCryptor().hashSecretWithKeyStretchingAndSalt(secret: rfidUidData, salt: rfidUsers.salt)
        }
        catch {
            TCSLogWithMark("error hashing key: \(error.localizedDescription)")
            return
        }
        guard let rfidUserDict = rfidUsers.userDict, let rfidUser = rfidUserDict[hashedUID]  else {
            TCSLogWithMark("No RFID user with uid: \(uid)")


            if shouldAllowLoginCardSetup==true {
                loginCardSetupButton.isHidden=false
                self.loginCardSetupButton.state = .on

                unprovisionedRfidUid=uid

            }
            else {
                passwordTextField.shake(self)
            }
            return
        }

        shortName = rfidUser.username
        let encryptedPasswordData = rfidUser.password


        guard let rfidUIDdata = Data(fromHexEncodedString: uid) else {
            TCSLogWithMark("invalid UID Data")
            passwordTextField.shake(self)
            return

        }

        guard let passwordData = try? PasswordCryptor().passwordDecrypt(encryptedDataWithSalt: encryptedPasswordData, rfidUID: rfidUIDdata, pin:pin) else {
            TCSLogWithMark("error decrypting password")
            cardLoginFailedAttempts += 1
            passwordTextField.shake(self)
            return
        }
        cardLoginFailedAttempts = 0
        passString = String(decoding: passwordData, as: UTF8.self)
        let fullName = rfidUser.fullName
        let useruid = rfidUser.userUID

        TCSLogWithMark("UserID: \(useruid.stringValue)")
        let userExists = try? PasswordUtils.isUserLocal(shortName)
        guard let userExists = userExists else {
            TCSLogWithMark("DS error")
            passwordTextField.shake(self)
            return
        }
        if (userExists==true){
            TCSLogWithMark()
            processLogin(inShortname: shortName, inPassword: passString)
            return
        }
        //user is defined in rfid user file but never logged in. so new user,
        // so we populate the needed values for the account and move along
        setRequiredHintsAndContext()
        if let fullName = fullName {
            TCSLogWithMark("Setting fullName to \(fullName)")

            mechanismDelegate?.setHint(type: .fullName, hint: fullName as NSSecureCoding)

        }
        if useruid.intValue>499 {
            TCSLogWithMark("Setting uid to \(useruid.stringValue)")
            mechanismDelegate?.setHint(type: .uid, hint: useruid.stringValue as NSSecureCoding)
        }

        else if useruid.intValue != -1 {
            TCSLogWithMark("invalid uid. selecting next available UID.")

        }

        completeLogin(authResult:.allow)

    }
    func updateSize(){
        self.view.frame = CGRectMake(self.view.frame.origin.x, self.view.frame.origin.y, self.view.frame.size.width, self.stackView.frame.size.height +  64)
    
    }
    override func viewDidLayout() {

        TCSLogWithMark("viewDidLayout")
        updateSize()
    }

    @objc func setupLoginAppearance() {
        TCSLogWithMark()
        self.view.layer?.cornerRadius=15
        let ccidSlotName = DefaultsOverride.standardOverride.string(forKey: PrefKeys.ccidSlotName.rawValue)

        let shouldAllowLoginCardSetup = DefaultsOverride.standardOverride.bool(forKey: PrefKeys.shouldAllowLoginCardSetup.rawValue)

        tapLoginLabel.isHidden=true
        loginCardSetupButton.isHidden=true
        self.loginCardSetupButton.state = .off

        if let _ = ccidSlotName {
            if let _ = rfidUsers {
                //we have users so show text
                tapLoginLabel.isHidden=false
            }
            else {
                tapLoginLabel.isHidden=true
            }

            if shouldAllowLoginCardSetup == true {
                tapLoginLabel.isHidden=false

            }

        }

        alertTextField.isHidden=true

        self.usernameTextField.stringValue=""
        self.passwordTextField.stringValue=""

        logoImageView.isHidden=false
        if DefaultsOverride.standardOverride.bool(forKey: PrefKeys.shouldHideLoginWindowLogo.rawValue) == true {
            logoImageView.isHidden=true

        }
        else if let loginWindowLogoPath = DefaultsOverride.standardOverride.string(forKey: PrefKeys.loginWindowLogoPath.rawValue){
            if let image = NSImage.imageFromPathOrURL(pathURLString: loginWindowLogoPath){
                logoImageView.image=image
            }
        }
        self.usernameTextField.wantsLayer=true
        self.view.wantsLayer=true
//        self.view.frame=CGRectInset(self.view.frame, 0,32+128-logoImageView.frame.height)
        self.view.layer?.backgroundColor = CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.7)
        localOnlyCheckBox.isEnabled=true
        localOnlyCheckBox.isHidden=false
        // make things look better
        TCSLogWithMark("Tweaking appearance")

        if let usernamePlaceholder = UserDefaults.standard.string(forKey: PrefKeys.usernamePlaceholder.rawValue){
            TCSLogWithMark("Setting username placeholder: \(usernamePlaceholder)")
            self.usernameTextField.placeholderString=usernamePlaceholder
        }
        self.usernameTextField.isEnabled=true

        if let passwordPlaceholder = UserDefaults.standard.string(forKey: PrefKeys.passwordPlaceholder.rawValue){
            TCSLogWithMark("Setting password placeholder")

            self.passwordTextField.placeholderString=passwordPlaceholder

        }
        passwordTextField.isEnabled=true
        signIn.isEnabled=true
        TCSLogWithMark("Domain is \(domainName)")
        if UserDefaults.standard.bool(forKey: PrefKeys.shouldShowLocalOnlyCheckbox.rawValue) == false {
            TCSLogWithMark("hiding local only")

            self.localOnlyCheckBox.isHidden = true
            self.localOnlyCheckBox.isHidden = true
        }
        else {
            //show based on if there is an AD domain or not

            let isLocalOnly = self.domainName.isEmpty == true && UserDefaults.standard.bool(forKey: PrefKeys.shouldUseROPGForLoginWindowLogin.rawValue) == false
            self.localOnlyCheckBox.isHidden = isLocalOnly
            self.localOnlyCheckBox.isHidden = isLocalOnly

        }

    }

    func showResetUI() throws  {
        TCSLogWithMark()

        let changePasswordWindowController = UpdatePasswordWindowController.init(windowNibName: NSNib.Name("UpdatePasswordWindowController"))

        changePasswordWindowController.window?.canBecomeVisibleWithoutLogin=true
        changePasswordWindowController.window?.isMovable = true
        changePasswordWindowController.window?.canBecomeVisibleWithoutLogin = true
        changePasswordWindowController.window?.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue)
        TCSLogWithMark("resetting level")
        changePasswordWindowController.window?.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue)

        changePasswordWindowController.window?.forceToFrontAndFocus(self)
        let response = NSApp.runModal(for: changePasswordWindowController.window!)
        changePasswordWindowController.window?.close()
        TCSLogWithMark("response: \(response.rawValue)")

        if response == .cancel {
            throw SignInViewControllerResetPasswordError.cancelled
        }

        if let pass = changePasswordWindowController.password {
            newPassword = pass
        }
        if let currPassword = changePasswordWindowController.currentPassword {
            passString=currPassword
        }

        isResetPasswordInProgress=true


        networkAuth()
    }

    fileprivate func shakeWindowAndShowError(_ message: String?=nil) {
        XCredsAudit().auditError(message ?? "Empty")
        TCSLogWithMark(message ?? "")
        nomadSession = nil
        passwordTextField.stringValue = ""
        passwordTextField.shake(self)
        alertTextField.isHidden=false
        if message?.lowercased() == "preauthentication failed" {
            alertTextField.stringValue = "Authentication Failed"
        }
        else if message?.lowercased() == "unknown ad user" {
            alertTextField.stringValue = "Authentication Failed"
        }
        else {
            alertTextField.stringValue = message ?? "Authentication Failed"
        }
        setLoginWindowState(enabled: true)
        view.window?.makeFirstResponder(passwordTextField)
    }

    /// Simple toggle to change the state of the NoLo window UI between active and inactive.
    fileprivate func setLoginWindowState(enabled:Bool) {
        TCSLogWithMark()

        if signIn != nil && usernameTextField != nil && passwordTextField != nil && localOnlyCheckBox != nil {
            signIn.isEnabled = enabled
            TCSLogWithMark()
            usernameTextField.isEnabled = enabled
            passwordTextField.isEnabled = enabled
            localOnlyCheckBox.isEnabled = enabled

            TCSLogWithMark()
        }
    }

    func setupLoginCard(completion:(_ result:Bool, _ pin:String?)->Void) {

        let pinSetWindowController = PinSetWindowController(windowNibName: "PinSetWindowController")
        let res = NSApp.runModal(for: pinSetWindowController.window!)

        if res == .cancel {
           pinSetWindowController.window?.close()
           completion(false,nil)
           return
       }

        else {
            completion(true,pinSetWindowController.pin)
        }



//        if setupCardWindowController == nil {
//            setupCardWindowController = SetupCardWindowController(windowNibName:"SetupCardWindowController")
//        }
//        setupCardWindowController?.window?.canBecomeVisibleWithoutLogin=true

//        if let setupCardWindow = setupCardWindowController?.window {
//            let res = NSApp.runModal(for: setupCardWindow)
//            if res == .OK {
//                if let uid = setupCardWindowController?.uid {
//                    completion(true, uid, setupCardWindowController?.pin)
//                }
//                else {
//                    TCSLogWithMark("no uid")
//                }
//            }
//            else {
//                TCSLogWithMark("result is not ok")
//                setupCardWindowController=nil
//                completion(false,nil, nil)
//
//            }
//        }
    }

    /// When the sign in button is clicked we check a few things.
    ///
    /// 1. Check to see if the username field is blank, bail if it is. If not, animate the UI and process the user strings.
    ///
    /// 2. Check the user shortname and see if the account already exists in DSLocal. If so, simply set the hints and pass on.
    ///
    /// 3. Create a `NoMADSession` and see if we can authenticate as the user.
    @IBAction func signInButtonPressed(_ sender: Any) {
        TCSLogWithMark("Sign In button pressed")
        let strippedUsername = usernameTextField.stringValue.trimmingCharacters(in:  CharacterSet.whitespaces)

        if strippedUsername.isEmpty {
            usernameTextField.shake(self)
            TCSLogWithMark("No username entered")
            return
        }
        else if passString.isEmpty {
            passwordTextField.shake(self)
            view.window?.makeFirstResponder(passwordTextField)

            TCSLogWithMark("No password entered")
            return
        }
        if (self.localOnlyCheckBox.state == .off)  {
            updateLoginWindowInfo()
        }
        else {

            shortName = strippedUsername
        }
        processLogin(inShortname: shortName, inPassword: passString)

    }

    func processLogin(inShortname:String, inPassword:String)  {

        TCSLogWithMark()

        setLoginWindowState(enabled: false)

        if (self.domainName.isEmpty==true && UserDefaults.standard.bool(forKey: PrefKeys.shouldUseROPGForLoginWindowLogin.rawValue) == false) || self.localOnlyCheckBox.state == .on{
            TCSLogWithMark("do local auth only")
            guard let resolvedName = try? PasswordUtils.resolveName(shortName) else {
                usernameTextField.shake(self)
                passwordTextField.shake(self)
                TCSLogWithMark("No user found for user \(shortName)")
                shakeWindowAndShowError()
                return
            }
            shortName = resolvedName

            switch PasswordUtils.isLocalPasswordValid(userName: shortName, userPass: passString) {

            case .success:
                setRequiredHintsAndContext()
                mechanismDelegate?.setHint(type: .localLogin, hint: true as NSSecureCoding )

                if loginCardSetupButton.state == .on, let uid = unprovisionedRfidUid {
                    shouldIgnoreInsertion=true
                    setupLoginCard { result,pin  in
                        if result==true{

                            TCSLogWithMark("setting rfid uid: \(uid)")
                            mechanismDelegate?.setHint(type: .rfidUid, hint: uid as NSSecureCoding)

                            if let pin = pin {
                                TCSLogWithMark("setting pin")
                                mechanismDelegate?.setHint(type: .rfidPIN, hint: pin as NSSecureCoding)
                            }
                            shouldIgnoreInsertion=false
                            completeLogin(authResult:.allow)
                        }
                        else {
                            shouldIgnoreInsertion=false
                            TCSLogWithMark("failed to set up Login card")
                            shakeWindowAndShowError("Login Card Setup Failed")
                            return

                        }

                    }
                }
                else {
                    completeLogin(authResult:.allow)
                    return

                }

            case .incorrectPassword:
                TCSLogWithMark("incorrectPassword")
                shakeWindowAndShowError()
                return

            case .accountDoesNotExist:
                TCSLogWithMark("accountDoesNotExist")
                shakeWindowAndShowError()
                return

            case .accountLocked:
                TCSLogWithMark("accountLocked so we prompt")
                if let mech = mechanismDelegate {
                    
                    let localAdmin = mech.getHint(type: .localAdmin) as? LocalAdminCredentials
                    self.localAdmin = localAdmin
                    switch mech.unsyncedPasswordPrompt(username: inShortname, password: inPassword, accountLocked: true, localAdmin: localAdmin, showResetButton: true){

                    case .success:
                        setRequiredHintsAndContext()
                        mechanismDelegate?.setHint(type: .localLogin, hint: true as NSSecureCoding )
                        completeLogin(authResult:.allow)
                        break
                    case .failure(_):
                        shakeWindowAndShowError("account locked auth failure")
                        return

                    case .userCancelled:
                        shakeWindowAndShowError("Account locked, user cancelled")
                        return

                    }
                }
                else {
                    TCSLogWithMark("the mechanism delegate is nil")
                    shakeWindowAndShowError()
                    return
                }

            case .other(let mesg ):
                TCSLogWithMark("message: \(mesg)")
                shakeWindowAndShowError()
                return
            }
        }
        else if UserDefaults.standard.bool(forKey: PrefKeys.shouldUseROPGForLoginWindowLogin.rawValue) == true {

            TCSLogWithMark("Checking credentials using ROPG")

            tokenManager.feedbackDelegate=self

            shortName = inShortname

            let shouldUseBasicAuthWithROPG = DefaultsOverride.standardOverride.bool(forKey: PrefKeys.shouldUseBasicAuthWithROPG.rawValue)

            var overrrideErrorArray = [String]()
            let ropgResponseValue = DefaultsOverride.standardOverride.string(forKey: PrefKeys.ropgResponseValue.rawValue)

            if let ropgResponseValue = ropgResponseValue {
                overrrideErrorArray.append(ropgResponseValue)
            }

            Task{

                //Try with ROPG. We cannot override errors because otherwise we don't get a token back so that is bad.
                //so that means no MFA, but that is fine since we are interactive login and if you wanted MFA, you can
                //use a different OIDC flow with a web view.

                do{
                    let tokenResponse = try await tokenManager.oidc().requestTokenWithROPG(username: inShortname, password: inPassword, basicAuth: shouldUseBasicAuthWithROPG, overrideErrors: nil)

                    //
                    if tokenResponse==nil {
                        tokenError("ROPG failed. No token returned.")
                        return
                    }

                    if let tokenResponse = tokenResponse {
                        _ = Creds(password: inPassword, tokens: tokenResponse)
                        completeLogin(authResult:.allow)

                    }
                }
                catch {
                    shakeWindowAndShowError("ROPG failed: \(error.localizedDescription)")

                }
            }
        }
        else { // AD. So auth
            TCSLogWithMark("network auth.")
            networkAuth()
        }
    }
    fileprivate func networkAuth() {

        if shortName.isEmpty {
            if let user = try? PasswordUtils.getLocalRecord(getConsoleUser()),
                  let kerbPrincArray = user.value(forKey: "dsAttrTypeNative:_xcreds_activedirectory_kerberosPrincipal") as? Array <String>,
               let kerbPrinc = kerbPrincArray.first
            {
                shortName=kerbPrinc
            }
        }


        if domainName.isEmpty, let prefDomainName=getManagedPreference(key: .ADDomain) as? String{
            domainName = prefDomainName
        }
        nomadSession = NoMADSession.init(domain: domainName, user: shortName)
        TCSLogWithMark("NoMAD Login User: \(shortName), Domain: \(domainName)")
        guard let session = nomadSession else {
            TCSLogErrorWithMark("Could not create NoMADSession")
            return
        }
        session.useSSL = isSSLRequired
        session.userPass = passString
        session.delegate = self
        session.recursiveGroupLookup = getManagedPreference(key: .RecursiveGroupLookup) as? Bool ?? false
        

        if let customLDAPAttributes = getManagedPreference(key: .CustomLDAPAttributes) as? Array<String> {
            TCSLogWithMark("Adding requested Custom Attributes:\(customLDAPAttributes)")
            session.customAttributes=customLDAPAttributes
        }

        if let ignoreSites = getManagedPreference(key: .IgnoreSites) as? Bool {
            os_log("Ignoring AD sites", log: uiLog, type: .debug)

            session.siteIgnore = ignoreSites
        }
        
        if let ldapServers = getManagedPreference(key: .LDAPServers) as? [String] {
            TCSLogWithMark("Adding custom LDAP servers")

            session.ldapServers = ldapServers
        }
        
        TCSLogWithMark("Attempt to authenticate user")
        session.authenticate()
    }


    /// Format the user and domain from the login window depending on the mode the window is in.
    ///
    /// I.e. are we picking a domain from a list, using a managed domain, or putting it on the user name with '@'.
    fileprivate func updateLoginWindowInfo() {

        TCSLogWithMark("Format user and domain strings")
        TCSLogWithMark()

        domainName = ""
        let strippedUsername = usernameTextField.stringValue.trimmingCharacters(in:  CharacterSet.whitespaces)
        shortName = strippedUsername


        TCSLogWithMark()
        let adDomainFromPrefs = DefaultsOverride.standardOverride.string(forKey: PrefKeys.aDDomain.rawValue)
        var allDomainsFromPrefs = DefaultsOverride.standardOverride.array(forKey: PrefKeys.additionalADDomainList.rawValue)  as? [String] ?? []

        if let adDomainFromPrefs=adDomainFromPrefs  {
            allDomainsFromPrefs.append(adDomainFromPrefs)
        }
        allDomainsFromPrefs = allDomainsFromPrefs.map { currVal in
            currVal.uppercased()
        }

        if strippedUsername.range(of:"@") != nil {
            shortName = (strippedUsername.components(separatedBy: "@").first)!

            if let providedDomainName = (strippedUsername.components(separatedBy: "@").last)?.uppercased(){
                domainName = providedDomainName

            }
        }

        if let upnMappings = DefaultsOverride.standardOverride.array(forKey: PrefKeys.upnSuffixToDomainMappings.rawValue)  as? [[String:String]]{
            for upnMapping in upnMappings {
                if let upn = upnMapping["upn"]?.uppercased(),
                    let mappedDomain = upnMapping["domain"]?.uppercased(),
                    upn == domainName.uppercased()
                {
                    TCSLogWithMark("changing domain from \(domainName) to \(mappedDomain)")
                    domainName = mappedDomain
                    break
                }

            }
        }



        if domainName != "", allDomainsFromPrefs.contains(domainName.uppercased())==false {
            TCSLogWithMark("domain \(domainName) is not the adDomain or in additionalADDomainList.")
            domainName = ""
        }
        if  domainName == "",
            let managedDomain = getManagedPreference(key: .ADDomain) as? String {
            TCSLogWithMark("Defaulting to managed domain as there is nothing else")
            domainName = managedDomain
            TCSLogWithMark("Using domain from managed domain")

        }
        return
    }


    //MARK: - Login Context Functions

    /// Set the authorization and context hints. These are the basics we need to passthrough to the next mechanism.
    fileprivate func setRequiredHintsAndContext() {
        TCSLogWithMark()
        TCSLogWithMark("Setting hints for user: \(shortName)")
        TCSLogWithMark("Setting user to \(shortName)")

        mechanismDelegate?.setHint(type: .user, hint: shortName as NSSecureCoding)
        mechanismDelegate?.setHint(type: .pass, hint: passString as NSSecureCoding)
        TCSLogWithMark()
        os_log("Setting context values for user: %{public}@", log: uiLog, type: .debug, shortName)
        mechanismDelegate?.setContextString(type: kAuthorizationEnvironmentUsername, value: shortName)
        mechanismDelegate?.setContextString(type: kAuthorizationEnvironmentPassword, value: passString)
        TCSLogWithMark()

    }


    /// Complete the login process and either continue to the next Authorization Plugin or reset the NoLo window.
    ///
    /// - Parameter authResult:`Authorizationresult` enum value that indicates if login should proceed.
    fileprivate func completeLogin(authResult: AuthorizationResult) {


        switch authResult {
        case .allow:
            TCSLogWithMark("Complete login process with allow")
            XCredsAudit().loginWindowLogin(user:shortName)
            mechanismDelegate?.allowLogin()

        case .deny:
            TCSLogWithMark("Complete login process with deny")
            mechanismDelegate?.denyLogin(message:nil)
            NotificationCenter.default.post(name: Notification.Name("TCSTokensUpdated"), object: self, userInfo:["error":"Login Denied","cause":authResult])


        case .userCanceled:
            TCSLogWithMark("Complete login process with deny")
            mechanismDelegate?.denyLogin(message:nil)
            NotificationCenter.default.post(name: Notification.Name("TCSTokensUpdated"), object: self, userInfo:["error":"User Cancelled", "cause":authResult])

        default:
            TCSLogWithMark("deny login process with unknown error")
            mechanismDelegate?.denyLogin(message:nil)
            NotificationCenter.default.post(name: Notification.Name("TCSTokensUpdated"), object: self, userInfo:["error":"Unknown error","cause":authResult])

        }
        TCSLogWithMark()
//        NSApp.stopModal()
    }

    //MARK: - Update Local User Account Methods

//    fileprivate func showPasswordSync() {
//        // hide other possible boxes
//        TCSLogWithMark()
//
//        let passwordWindowController = PromptForLocalPasswordWindowController.init(windowNibName: NSNib.Name("LoginPasswordWindowController"))
//
//        passwordWindowController.window?.canBecomeVisibleWithoutLogin=true
//        passwordWindowController.window?.isMovable = false
//        passwordWindowController.window?.canBecomeVisibleWithoutLogin = true
//        passwordWindowController.window?.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue)
//        var isDone = false
//        while (!isDone){
//            DispatchQueue.main.async{
//                TCSLogWithMark("resetting level")
//                passwordWindowController.window?.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue)
//            }
//
//            let response = NSApp.runModal(for: passwordWindowController.window!)
//            passwordWindowController.window?.close()
//
//            if response == .cancel {
//                isDone=true
//                TCSLogWithMark("User cancelled resetting keychain or entering password. Denying login")
//                completeLogin(authResult: .deny)
//
//                return
//            }
//
//            let localPassword = passwordWindowController.password
//            guard let localPassword = localPassword else {
//                continue
//            }
//            do {
//                os_log("Password doesn't match existing local. Try to change local pass to match.", log: uiLog, type: .default)
//                let localUser = try getLocalRecord(shortName)
//                try localUser.changePassword(localPassword, toPassword: passString)
//                os_log("Password sync worked, allowing login", log: uiLog, type: .default)
//
//                isDone=true
//                mechanism?.setHint(type: .existingLocalUserPassword, hint: localPassword)
//                completeLogin(authResult: .allow)
//                return
//            } catch {
//                os_log("Unable to sync local password to Network password. Reload and try again", log: uiLog, type: .error)
//                return
//            }
//
//
//        }
//
//    }
    

    fileprivate func showMigration(password:String) {

        TCSLogWithMark()
        switch SelectLocalAccountWindowController.selectLocalAccountAndUpdate(newPassword: password) {

        case .successful(let username):
            TCSLogWithMark("Successful local account verification. Allowing")
            shortName = username
            setRequiredHintsAndContext()
            completeLogin(authResult: .allow)
            return

        case .canceled:
            TCSLogWithMark("selectLocalAccountAndUpdate cancelled")
            completeLogin(authResult: .deny)
            return
        case .createNewAccount:
            TCSLogWithMark("selectLocalAccountAndUpdate createNewAccount")
            completeLogin(authResult: .allow)

        case .error(let error):
            TCSLogWithMark("selectLocalAccountAndUpdate error:\(error)")
            completeLogin(authResult: .deny)

        }
        //need to prompt for username and passsword to select an account. Perhaps use code from the cloud login.
//        //RunLoop.main.perform {
//        // hide other possible boxes
//        os_log("Showing migration box", log: uiLog, type: .default)
//
//        self.loginStack.isHidden = true
//        self.signIn.isHidden = true
//        self.signIn.isEnabled = true
//
//        // show migration box
//        self.migrateBox.isHidden = false
//        self.migrateSpinner.isHidden = false
//        self.migrateUsers.addItems(withTitles: self.localCheck.migrationUsers ?? [""])
//        //}
    }
    
//    @IBAction func clickMigrationOK(_ sender: Any) {
//        RunLoop.main.perform {
//            self.migrateSpinner.isHidden = false
//            self.migrateSpinner.startAnimation(nil)
//        }
//        
//        let migrateUIPass = self.migratePassword.stringValue
//        if migrateUIPass.isEmpty {
//            os_log("No password was entered", log: uiLog, type: .error)
//            RunLoop.main.perform {
//                self.migrateSpinner.isHidden = true
//                self.migrateSpinner.stopAnimation(nil)
//            }
//            return
//        }
//        
//        // Take a look to see if we are syncing passwords. Until the next refactor the easiest way to tell is if the picklist is hidden.
//        if self.migrateUsers.isHidden {
//            do {
//                os_log("Password doesn't match existing local. Try to change local pass to match.", log: uiLog, type: .default)
//                let localUser = try getLocalRecord(shortName)
//                try localUser.changePassword(migrateUIPass, toPassword: passString)
//                didUpdateFail = false
//                passChanged = false
//                os_log("Password sync worked, allowing login", log: uiLog, type: .default)
//                delegate?.setHint(type: .existingLocalUserPassword, hint: migrateUIPass)
//                completeLogin(authResult: .allow)
//                return
//            } catch {
//                os_log("Unable to sync local password to Network password. Reload and try again", log: uiLog, type: .error)
//                didUpdateFail = true
//                showPasswordSync()
//                return
//            }
//        }
//        guard let migrateToUser = self.migrateUsers.selectedItem?.title else {
//            os_log("Could not select user to migrate from pick list.", log: uiLog, type: .error)
//            return
//        }
//        do {
//            os_log("Getting user record for %{public}@", log: uiLog, type: .default, migrateToUser)
//            migrateUserRecord = try getLocalRecord(migrateToUser)
//            os_log("Checking existing password for %{public}@", log: uiLog, type: .default, migrateToUser)
//            if migrateUIPass != passString {
//                os_log("No match. Upating local password for %{public}@", log: uiLog, type: .default, migrateToUser)
//                try migrateUserRecord?.changePassword(migrateUIPass, toPassword: passString)
//            } else {
//                os_log("Okta and local passwords matched for %{public}@", log: uiLog, type: .default, migrateToUser)
//            }
//            // Mark the record to add an alias if required
//            os_log("Setting hints for %{public}@", log: uiLog, type: .default, migrateToUser)
//            delegate?.setHint(type: .existingLocalUserName, hint: migrateToUser)
//            delegate?.setHint(type: .existingLocalUserPassword, hint: migrateUIPass)
//            os_log("Allowing login", log: uiLog, type: .default, migrateToUser)
//            completeLogin(authResult: .allow)
//        } catch {
//            os_log("Migration failed with: %{public}@", log: uiLog, type: .error, error.localizedDescription)
//            return
//        }
//        
//        // if we are here, the password didn't work
//        os_log("Unable to migrate user.", log: uiLog, type: .error)
//        self.migrateSpinner.isHidden = true
//        self.migrateSpinner.stopAnimation(nil)
//        self.migratePassword.stringValue = ""
//        self.completeLogin(authResult: .deny)
//    }
//    
//    @IBAction func clickMigrationCancel(_ sender: Any) {
//        passChanged = false
//        didUpdateFail = false
//        completeLogin(authResult: .deny)
//    }
//    
//    @IBAction func clickMigrationNo(_ sender: Any) {
//        // user doesn't want to migrate, so create a new account
//        completeLogin(authResult: .allow)
//    }
    
//    @IBAction func clickMigrationOverwrite(_ sender: Any) {
//        // user wants to overwrite their current password
//        os_log("Password Overwrite selected", log: uiLog, type: .default)
//        localCheck.mech = self.mech
//        delegate?.setHint(type: .passwordOverwrite, hint: true)
//        completeLogin(authResult: .allow)
//    }
    
//    @IBAction func showNetworkConnection(_ sender: Any) {
//        username.isHidden = true
//        guard let windowContentView = self.window?.contentView, let wifiView = WifiView.createFromNib(in: .mainLogin) else {
//            os_log("Error showing network selection.", log: uiLog, type: .debug)
//            return
//        }
//
//        wifiView.frame = windowContentView.frame
//        let completion = {
//            os_log("Finished working with wireless networks", log: uiLog, type: .debug)
//            self.username.isHidden = false
//            self.username.becomeFirstResponder()
//        }
//        wifiView.set(completionHandler: completion)
//        windowContentView.addSubview(wifiView)
//    }
//
//    @IBAction func clickInfo(_ sender: Any) {
//        if sysInfo.count > sysInfoIndex + 1 {
//            sysInfoIndex += 1
//        } else {
//            sysInfoIndex = 0
//        }
//
//        systemInfo.title = sysInfo[sysInfoIndex]
//        os_log("System information toggled", log: uiLog, type: .debug)
//    }
//    func verify() {
//
//            if XCredsBaseMechanism.checkForLocalUser(name: shortName) {
//                TCSLogWithMark()
//                os_log("Verify local user login for %{public}@", log: uiLog, type: .default, shortName)
//
//                if getManagedPreference(key: .DenyLocal) as? Bool ?? false {
//                    os_log("DenyLocal is enabled, looking for %{public}@ in excluded users", log: uiLog, type: .default, shortName)
//
//                    var exclude = false
//
//                    if let excludedUsers = getManagedPreference(key: .DenyLocalExcluded) as? [String] {
//                        if excludedUsers.contains(shortName) {
//                            os_log("Allowing local sign in via exclusions %{public}@", log: uiLog, type: .default, shortName)
//                            exclude = true
//                        }
//                    }
//
//                    if !exclude {
//                        os_log("No exclusions for %{public}@, denying local login. Forcing network auth", log: uiLog, type: .default, shortName)
//                        networkAuth()
//                        return
//                    }
//                }
//                TCSLogWithMark()
//                if PasswordUtils.verifyUser(name: shortName, auth: passString) {
//                    TCSLogWithMark()
//                    os_log("Allowing local user login for %{public}@", log: uiLog, type: .default, shortName)
//                    setRequiredHintsAndContext()
//                    TCSLogWithMark()
//                    completeLogin(authResult: .allow)
//                    return
//                } else {
//                    os_log("Could not verify %{public}@", log: uiLog, type: .default, shortName)
//                    authFail()
//                    return
//                }
//            }
//
//    }

}


//MARK: - NoMADUserSessionDelegate
@available(macOS, deprecated: 11)
extension SignInViewController: NoMADUserSessionDelegate {

    func NoMADAuthenticationFailed(error: NoMADSessionError, description: String) {

        if isResetPasswordInProgress==true {

            isResetPasswordInProgress=false

            if error == .PasswordExpired {
                TCSLogWithMark("Password expired so go ahead and changing it")
                changePassword()
                return

            }
            else {

                let alert = NSAlert()
                alert.addButton(withTitle: "OK")
                alert.messageText="Your current password is invalid. Please try again."

                alert.window.canBecomeVisibleWithoutLogin=true

                let bundle = Bundle.findBundleWithName(name: "XCreds")

                if let bundle = bundle {
                    TCSLogWithMark("Found bundle")
                    alert.icon=bundle.image(forResource: NSImage.Name("icon_128x128"))
                }
                alert.runModal()

                return
            }
        }
        updateCredentialsFeedbackDelegate?.kerberosTicketCheckFailed(error)

        TCSLogWithMark("AuthenticationFailed: \(description)")
        switch error {
        case .PasswordExpired:
            TCSLogErrorWithMark("Password is expired or requires change.")
            if DefaultsOverride().bool(forKey: PrefKeys.shouldPromptForADPasswordChange.rawValue) == false {

                shakeWindowAndShowError("Password is expired or requires change.")
                return
            }
            do {
                try showResetUI()
            }
            catch {
                TCSLogWithMark("\(error)")
                setLoginWindowState(enabled: true)

            }
        case .OffDomain, .UnknownPrincipal:
            TCSLogErrorWithMark("\(error)")

            if getManagedPreference(key: .LocalFallback) as? Bool ?? false, case .success = PasswordUtils.isLocalPasswordValid(userName: shortName, userPass: passString) {
                mechanismDelegate?.setHint(type: .localLogin, hint: true as NSSecureCoding)
                setRequiredHintsAndContext()
                completeLogin(authResult: .allow)
            } else {
                if error == .OffDomain {
                    TCSLogErrorWithMark("AD authentication failed, off domain.")
                    shakeWindowAndShowError("Cannot reach domain controller")

                }
                else if error == .UnknownPrincipal {
                    TCSLogErrorWithMark("AD authentication failed, Unknown AD User.")
                    shakeWindowAndShowError("Unknown AD User")
                }
                else {
                    TCSLogErrorWithMark("Unknown Error")
                    shakeWindowAndShowError("Unknown Error")

                }

            }
        default:
            TCSLogErrorWithMark("NoMAD Login Authentication failed with: \(description):\(error.rawValue)")

                shakeWindowAndShowError(description)
//
            return
        }
    }


    func NoMADAuthenticationSucceeded() {
        updateCredentialsFeedbackDelegate?.kerberosTicketUpdated()

        if getManagedPreference(key: .RecursiveGroupLookup) as? Bool ?? false {
            nomadSession?.recursiveGroupLookup = true
        }
        
        if isResetPasswordInProgress==true {
            TCSLogWithMark("changing password and then returning")
            isResetPasswordInProgress = false
            changePassword()
            return
        }
            // need to ensure the right password is stashed

        
        if isInUserSpace==true {
            if hadPasswordFailure==true {
                TCSLogWithMark("had password failure, updating keychain with new password")
                hadPasswordFailure = false
                try? updateCurrentUserKeychain(updatedPassword: passString)
            }

            self.view.window?.close()
        }
        TCSLogWithMark("Authentication succeeded, requesting user info")
        nomadSession?.userInfo()
    }

    func changePassword()  {
        TCSLogWithMark("Changing password")
        guard let session = nomadSession else {
            TCSLogWithMark("invalid session")
            return
        }
        session.oldPass = passString
        session.newPass = newPassword
        os_log("Attempting password change for %{public}@", log: uiLog, type: .debug, shortName)

        TCSLogWithMark("Attempting password change")

        do {
            try session.changeKerberosPassword()

            if isInUserSpace==true {
                try updateCurrentUserKeychain(updatedPassword: newPassword)
                passString = newPassword
                NotificationCenter.default.post(name: NSNotification.Name("KerberosPasswordChanged"), object: ["updatedPassword":newPassword])
                let alert = NSAlert()
                alert.addButton(withTitle: "OK")
                alert.messageText="Password changed successfully."

                alert.window.canBecomeVisibleWithoutLogin=true

                let bundle = Bundle.findBundleWithName(name: "XCreds")

                if let bundle = bundle {
                    TCSLogWithMark("Found bundle")
                    alert.icon=bundle.image(forResource: NSImage.Name("icon_128x128"))
                }
                alert.runModal()
                session.userPass = newPassword
                session.authenticate(authTestOnly: false)

            }
            else {
                TCSLogWithMark("Setting current password to change later and authenticating with new password")
                let localUser = try getLocalRecord(shortName)

                //try to change the password, but if the admin changed it out of band, we don't
                //fail here and prompt later
                try? localUser.changePassword(passString, toPassword: newPassword)

                mechanismDelegate?.setHint(type: .existingLocalUserPassword, hint: passString as NSSecureCoding)
                passString = newPassword
                session.userPass = newPassword
                session.authenticate(authTestOnly: false)

            }



        }
        catch {
            TCSLogWithMark("Error changing password: \(error)")
            let alert = NSAlert()
            alert.addButton(withTitle: "OK")
            alert.messageText="Error changing password"

            alert.window.canBecomeVisibleWithoutLogin=true

            let bundle = Bundle.findBundleWithName(name: "XCreds")

            if let bundle = bundle {
                TCSLogWithMark("Found bundle")
                alert.icon=bundle.image(forResource: NSImage.Name("icon_128x128"))
            }
            alert.runModal()

            setLoginWindowState(enabled: true)
        }
    }
    func updateCurrentUserKeychain(updatedPassword:String) throws  {
        let accountInfo = try KeychainUtil().findPassword(serviceName: PrefKeys.password.rawValue,accountName: nil)

        TCSLogWithMark("Getting account info.")

        guard let password = accountInfo?.password else {
            TCSLogWithMark("no password in keychain.")
            throw PasswordError.invalidResult("no password in keychain")

        }

        //change password on keychain and local account
        TCSLogWithMark("change password on keychain and local account.")

        try PasswordUtils.changeLocalUserAndKeychainPassword(password, newPassword: updatedPassword)

        //change entry in keychain to match new password
        TCSLogWithMark("change entry in keychain to match new password")

        if KeychainUtil().updatePassword(serviceName: "xcreds local password",accountName:PasswordUtils.currentConsoleUserName, pass:updatedPassword, shouldUpdateACL: true, keychainPassword: updatedPassword) == false {
            throw PasswordError.invalidResult("Error updating password in keychain")

        }
    }
//callback from ADAuth framework when userInfo returns
    func NoMADUserInformation(user: ADUserRecord) {

        TCSLogWithMark("User Info:\(user)")
        TCSLogWithMark("Groups:\(user.groups)")
        var allowedLogin = true

        if let passExpired = user.passwordExpire {
            updateCredentialsFeedbackDelegate?.passwordExpiryUpdate(passExpired)

        }
        updateCredentialsFeedbackDelegate?.adUserUpdated(user)

        TCSLogWithMark("Checking for DenyLogin groupsChecking for DenyLogin groups")
        
        if let allowedGroups = getManagedPreference(key: .DenyLoginUnlessGroupMember) as? [String] {
            TCSLogErrorWithMark("Found a DenyLoginUnlessGroupMember key value: \(allowedGroups.debugDescription)")
            
            // set the allowed login to false for now
            
            allowedLogin = false
            
            user.groups.forEach { group in
                if allowedGroups.contains(group) {
                    allowedLogin = true
                    TCSLogErrorWithMark("User is a member of %{public}@ group. Setting allowedLogin = true ")
                }
            }
        }
    
        let mapUID = DefaultsOverride.standardOverride.string(forKey: PrefKeys.mapUID.rawValue)

        if let mapUID = mapUID, let rawAttributes = user.rawAttributes, let uidString = rawAttributes[mapUID]  {
            mechanismDelegate?.setHint(type: .uid, hint: uidString as NSSecureCoding)

        }
        if let ntName = user.customAttributes?["msDS-PrincipalName"] as? String {
            TCSLogWithMark("Found NT User Name: \(ntName)")
            mechanismDelegate?.setHint(type: .ntName, hint: ntName as NSSecureCoding)
        }
        
        if allowedLogin {
            
            setHints(user: user)

            // check for any migration and local auth requirements
            let localCheck = LocalCheckAndMigrate()
            localCheck.isInUserSpace = self.isInUserSpace
            localCheck.delegate = mechanismDelegate
            switch localCheck.migrationTypeRequired(userToCheck: user.shortName, passToCheck: passString, kerberosPrincipalName:user.userPrincipal) {

            case .fullMigration:
                TCSLogWithMark()
                showMigration(password:passString)
            case .syncPassword:
                // first check to see if we can resolve this ourselves
                TCSLogWithMark("Sync password called.")

                let promptPasswordWindowController = VerifyLocalPasswordWindowController()

                promptPasswordWindowController.showResetText=true
                promptPasswordWindowController.showResetButton=true

                if isInUserSpace==true{
                    promptPasswordWindowController.showResetText=false
                    promptPasswordWindowController.showResetButton=false

                }
                var currUser = user.shortName
                TCSLogWithMark("switch  promptPasswordWindowController")
                if isInUserSpace == true {
                    let consoleUser = getConsoleUser()
                    currUser=consoleUser
                }
                else {
                    if let localAdmin = mechanismDelegate?.getHint(type: .localAdmin) as? LocalAdminCredentials, localAdmin.username.isEmpty==false {

                        promptPasswordWindowController.adminUsername=localAdmin.username

                        promptPasswordWindowController.adminPassword=localAdmin.password
                    }
                }


                switch  promptPasswordWindowController.promptForLocalAccountAndChangePassword(username: currUser, newPassword: passString, shouldUpdatePassword: true) {

                case .success(let enteredUsernamePassword):

                    TCSLogWithMark("setting original password to use to unlock keychain later")

                    if let enteredUsernamePassword = enteredUsernamePassword{
                        mechanismDelegate?.setHint(type: .existingLocalUserPassword, hint:enteredUsernamePassword.password as NSSecureCoding  )
                    }

                    completeLogin(authResult: .allow)

                case .accountResetRequested(let usernamePasswordCredentials):
                    TCSLogWithMark("resetKeychainRequested")

                    if let adminUsername = usernamePasswordCredentials?.username,
                       let adminPassword = usernamePasswordCredentials?.password {
                        let localAdmin = LocalAdminCredentials(username: adminUsername, password: adminPassword)
                        TCSLogWithMark("Setting local admin from settings")
                        mechanismDelegate?.setHint(type: .localAdmin, hint:localAdmin as NSSecureCoding )
                        mechanismDelegate?.setHint(type: .passwordOverwrite, hint: true as NSSecureCoding)
                        completeLogin(authResult: .allow)

                    }
                    else {
                        completeLogin(authResult: .deny)

                    }



                case .userCancelled:
                    TCSLogWithMark("userCancelled")

                    completeLogin(authResult: .userCanceled)


                case .error(_):
                    TCSLogWithMark("error")

                    completeLogin(authResult: .deny)
                }

            case .errorSkipMigration(let mesg):
                mechanismDelegate?.denyLogin(message:mesg)
            case .skipMigration, .userMatchSkipMigration, .complete:
                completeLogin(authResult: .allow)
//            case .mappedUserFound(let foundODUserRecord):
//                shortName = foundODUserRecord.recordName
//                TCSLogWithMark("Mapped user found: \(shortName)")
//                setRequiredHintsAndContext()
//                completeLogin(authResult: .allow)
            }
        } else {
            shakeWindowAndShowError()
            TCSLogWithMark("auth fail")
//            alertText.stringValue = "Not authorized to login."
//            showResetUI()
        }
    }
    
    fileprivate func setHints(user: ADUserRecord) {
        TCSLogWithMark()
        TCSLogWithMark("NoMAD Login Looking up info");
        setRequiredHintsAndContext()
        mechanismDelegate?.setHint(type: .firstName, hint: user.firstName as NSSecureCoding)
        mechanismDelegate?.setHint(type: .lastName, hint: user.lastName as NSSecureCoding)
        TCSLogWithMark("Setting user to \(user.shortName)")
        mechanismDelegate?.setHint(type: .user, hint: user.shortName as NSSecureCoding)
        mechanismDelegate?.setContextString(type: kAuthorizationEnvironmentUsername, value: user.shortName)

        mechanismDelegate?.setHint(type: .noMADDomain, hint: domainName as NSSecureCoding)
        mechanismDelegate?.setHint(type: .groups, hint: user.groups as NSSecureCoding)
        mechanismDelegate?.setHint(type: .fullName, hint: user.fullName as NSSecureCoding)
        TCSLogWithMark("setting kerberos principal to \(user.userPrincipal)")

        mechanismDelegate?.setHint(type: .kerberos_principal, hint: user.userPrincipal as NSSecureCoding)
        mechanismDelegate?.setHint(type: .ntName, hint: user.ntName as NSSecureCoding)

        // set the network auth time to be added to the user record
        mechanismDelegate?.setHint(type: .networkSignIn, hint: String(describing: Date.init().description) as NSSecureCoding)

        if let userAttributes = user.rawAttributes{
            TCSLogWithMark("Setting AD user attributes")
            mechanismDelegate?.setHint(type: .allADAttributes, hint:userAttributes as NSSecureCoding )

        }

    }

}


//MARK: - NSTextField Delegate
@available(macOS, deprecated: 11)
extension SignInViewController: NSTextFieldDelegate {
    public func controlTextDidChange(_ obj: Notification) {
        let passField = obj.object as! NSTextField
        if passField.tag == 99 {
            passString = passField.stringValue
        }
    }
}


//MARK: - ContextAndHintHandling Protocol
//extension SignIn: ContextAndHintHandling {}

extension NSWindow {

    func shakeWindow(){
        let numberOfShakes      = 3
        let durationOfShake     = 0.25
        let vigourOfShake : CGFloat = 0.015

        let frame : CGRect = self.frame
        let shakeAnimation :CAKeyframeAnimation  = CAKeyframeAnimation()

        let shakePath = CGMutablePath()
        shakePath.move(to: CGPoint(x: frame.minX, y: frame.minY))

        for _ in 0...numberOfShakes-1 {
            shakePath.addLine(to: CGPoint(x: frame.minX - frame.size.width * vigourOfShake, y: frame.minY))
            shakePath.addLine(to: CGPoint(x: frame.minX + frame.size.width * vigourOfShake, y: frame.minY))
        }

        shakePath.closeSubpath()

        shakeAnimation.path = shakePath;
        shakeAnimation.duration = durationOfShake;

        self.animations = [NSAnimatablePropertyKey("frameOrigin"):shakeAnimation]
        self.animator().setFrameOrigin(self.frame.origin)
    }

}

