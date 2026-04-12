/// Maps OTN user email → full display name used as OneDrive folder name.
/// Source: OTN_credentials.xlsx
/// Format in OneDrive: OTN Recorder / DD-MM-YYYY / <fullName> / filename.mp4
const Map<String, String> kOtnUserNames = {
  '1001@otn.in': 'Buri Sravani',
  '1002@otn.in': 'Ramya Arepalli',
  '1003@otn.in': 'Ete.prabharani',
  '1004@otn.in': 'Thatipudi Jyothi',
  '1005@otn.in': 'Aruna Vemavarapu',
  '1006@otn.in': 'B mounika',
  '1007@otn.in': 'Sri Usha',
  '1008@otn.in': 'Thatipudi usha rani',
  '1009@otn.in': 'Baby M subham-5',
  '1010@otn.in': 'THATIPUDI subha laxmi',
  '1011@otn.in': 'SUNITHA PATIBANDLA',
  '1012@otn.in': 'Sheik Swathi',
  '1013@otn.in': 'Priyanka Bejji',
  '1014@otn.in': 'K latha',
  '1015@otn.in': 'Padma Bhogapu',
  '1016@otn.in': 'B Sarada',
  '1017@otn.in': 'Kanaka mahalakshmi Bora',
  '1018@otn.in': 'Bevara Hemalatha',
  '1019@otn.in': 'YAMUNA NANDIVADA',
  '1020@otn.in': 'M.sruthi',
  '1021@otn.in': 'V Kumari',
  '1022@otn.in': 'Thatipudi sharon',
  '1023@otn.in': 'Riyaaz Parveen',
  '1024@otn.in': 'Neelapu tulasi sri',
  '1025@otn.in': 'B soundharya vangara',
  '1026@otn.in': 'N jagadeesh',
  '1027@otn.in': 'Pavani U',
  '1028@otn.in': 'T.Dhanalaxmi',
  '1029@otn.in': 'Margana Nalini',
  '1030@otn.in': 'Swapna Kamana hyd',
  '1031@otn.in': 'G lavanya',
  '1032@otn.in': 'Harini U',
  '1033@otn.in': 'Sravani T',
  '1034@otn.in': 'Deshmukh milan',
  '1035@otn.in': 'Lahari Kosanam',
  '1036@otn.in': 'Vijayalakshmi panyam',
  '1037@otn.in': 'P kumari',
  '1038@otn.in': 'Vanitha sri.G',
  '1039@otn.in': 'Parupalli shapona',
  '1040@otn.in': 'B Sandhya rayipalem',
};

/// Returns the OneDrive folder name for a given Firebase email.
/// Falls back to the email prefix if not found.
String getOneDriveFolderName(String email) {
  return kOtnUserNames[email.toLowerCase()] ?? email.split('@').first;
}